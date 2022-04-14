### usage:
# ./restoreSQLDBs.ps1 -vip mycluster `
#                     -username myusername `
#                     -domain mydomain.net `
#                     -sourceServer sqlserver1.mydomain.net `
#                     -allDBs `
#                     -overWrite `
#                     -latest

### process commandline arguments
[CmdletBinding()]
param (
    [Parameter(Mandatory = $True)][string]$vip,            # the cluster to connect to (DNS name or IP)
    [Parameter(Mandatory = $True)][string]$username,       # username (local or AD)
    [Parameter()][string]$domain = 'local',                # local or AD domain
    [Parameter()][string]$password,                        # optional password
    [Parameter()][switch]$useApiKey,                       # use API key for authentication
    [Parameter(Mandatory = $True)][string]$sourceServer,   # protection source where the DB was backed up
    [Parameter()][string]$sourceInstance = $null,          # source instance name
    [Parameter()][array]$sourceDBnames,                    # names of the source DBs we want to restore
    [Parameter()][string]$sourceDBList = '',               # text file containing DB names
    [Parameter()][switch]$allDBs,                          # restore all DBs
    [Parameter()][string]$targetServer = $sourceServer,    # where to restore the DB to
    [Parameter()][string]$prefix = $null,                  # prefix to add to DB names
    [Parameter()][string]$suffix = $null,                  # suffix to add to DB names
    [Parameter()][switch]$overWrite,                       # overwrite existing DB
    [Parameter()][string]$mdfFolder,                       # path to restore the mdf
    [Parameter()][string]$ldfFolder = $mdfFolder,          # path to restore the ldf
    [Parameter()][hashtable]$ndfFolders,                   # paths to restore the ndfs (requires Cohesity 6.0x)
    [Parameter()][string]$logTime,                         # date time to replay logs to e.g. '2019-01-20 02:01:47'
    [Parameter()][switch]$wait,                            # wait for completion
    [Parameter()][string]$targetInstance,                  # SQL instance name on the targetServer
    [Parameter()][switch]$latest,                          # replay logs to loatest available point in time
    [Parameter()][switch]$noRecovery,                      # leave DB in restore mode
    [Parameter()][switch]$progress,                        # show progress
    [Parameter()][switch]$noStop,                          # replay last log transactions
    [Parameter()][switch]$showPaths,                       # show data file paths and exit
    [Parameter()][switch]$useSourcePaths,                  # use same paths from source server for target server
    [Parameter()][switch]$includeSystemDBs,                # experimental
    [Parameter()][switch]$forceAlternateLocation,          # use alternate location params even when target server name is the same
    [Parameter()][switch]$exportFileInfo,                  # export DB file paths
    [Parameter()][switch]$importFileInfo                   # import DB file paths
)

### source the cohesity-api helper code
. $(Join-Path -Path $PSScriptRoot -ChildPath cohesity-api.ps1)

### authenticate
if($useApiKey){
    apiauth -vip $vip -username $username -domain $domain -useApiKey -password $password
}else{
    apiauth -vip $vip -username $username -domain $domain -password $password
}

$exportFilePath = Join-Path -Path $PSScriptRoot -ChildPath "$sourceServer.json"

### exportFileInfo
if($exportFileInfo){
    $entities = api get "/appEntities?appEnvType=3&envType=3"

    $sourceEntity = $entities | where-object { $_.appEntity.entity.displayName -eq $sourceServer }
    if($null -eq $sourceEntity){
        Write-Host "Source Server Not Found" -ForegroundColor Yellow
        exit 1
    }
    
    $fileInfoVec = @()
    
    foreach($instance in $sourceEntity.appEntity.auxChildren){
        foreach($database in $instance.children){
            $dbName = $database.entity.displayName
            $fileInfo = $database.entity.sqlEntity.dbFileInfoVec
            $fileInfoVec = @($fileInfoVec + @{
                'name' = $dbName
                'fileInfo' = $fileInfo
            })
        }
    }
    $fileInfoVec | ConvertTo-JSON -Depth 99 | Out-File -Path $exportFilePath
    "Exported file paths to $exportFilePath"
    exit 0
}

if($importFileInfo){
    if(!(Test-Path -Path $exportFilePath)){
        Write-Host "Import file $exportFilePath not found" -ForegroundColor Yellow
        exit 1
    }
    $importedFileInfo = Get-Content -Path $exportFilePath | ConvertFrom-JSON -Depth 99
}

### gather DB names
$dbs = @()
if($sourceDBList -ne '' -and (Test-Path $sourceDBList -PathType Leaf)){
    $dbs += Get-Content $sourceDBList | Where-Object {$_ -ne ''}
}elseif($sourceDBList -ne ''){
    Write-Warning "File $sourceDBList not found!"
    exit 1
}
if($sourceDBnames){
    $dbs += $sourceDBnames
}
if((! $allDBs) -and $dbs.Length -eq 0){
    Write-Host "No databases selected for restore"
    exit 1
}

### search for databases on sourceServer
$searchresults = api get "/searchvms?environment=SQL&entityTypes=kSQL&vmName=$sourceServer"

### narrow to the correct sourceServer
$dbresults = $searchresults.vms | Where-Object {$_.vmDocument.objectAliases -eq $sourceServer}

### if there are multiple results (e.g. old/new jobs?) select the one with the newest snapshot
$dbresults = $dbresults | Sort-Object -Property @{Expression={$_.vmDocument.versions[0].snapshotTimestampUsecs}; Ascending = $False} |
                          Group-Object -Property @{Expression={$_.vmDocument.objectName}} |
                          ForEach-Object {$_.Group[0]}

### narrow by sourceInstance
if($sourceInstance){
    $dbresults = $dbresults | Where-Object {($_.vmDocument.objectName -split '/')[0] -eq $sourceInstance}
}

if(! $dbresults){
    Write-Host "No Databases found for restore" -ForegroundColor Yellow
    exit 1
}

### alert on missing DBs
$selectedDBs = @()
foreach($db in $dbs){
    if(! $db.Contains('/')){
        if($sourceInstance){
            $db = "$sourceInstance/$db"
        }else{
            $db = "MSSQLSERVER/$db"
        }
    }
    $dbresult = $dbresults | Where-Object {$_.vmDocument.objectName -eq $db}
    if(! $dbresult){
        Write-Host "Database $db not found!" -ForegroundColor Yellow
    }else{
        $selectedDBs += $db
    }
}

### identify physical or vm
$entityType = $dbresults[0].registeredSource.type

### get entities
$entities = api get /appEntities?appEnvType=3`&envType=$entityType

### get target server entity
if(($targetServer -ne $sourceServer) -or $forceAlternateLocation){
    $targetEntity = $entities | where-object { $_.appEntity.entity.displayName -eq $targetServer }
    if($null -eq $targetEntity){
        Write-Host "Target Server Not Found" -ForegroundColor Yellow
        exit 1
    }
}

if($targetInstance -ne '' -and $targetInstance -ne $sourceInstance){
    $differentInstance = $True
}else{
    $differentInstance = $False
}

if($prefix -or $suffix -or $targetServer -ne $sourceServer -or $differentInstance -or $forceAlternateLocation){
    if('' -eq $mdfFolder -and ! $showPaths -and ! $useSourcePaths){
        write-host "-mdfFolder must be specified when restoring to a new database name or different target server" -ForegroundColor Yellow
        exit 1
    }
}

### overwrite warning
if((! $prefix) -and (! $suffix) -and $targetServer -eq $sourceServer -and $differentInstance -eq $False){
    if(! $overWrite -and ! $showPaths){
        write-host "Please use the -overWrite parameter to confirm overwrite of the source database!" -ForegroundColor Yellow
        exit
    }
}

function restoreDB($db){
    $sourceInstance, $sourceDBname = $db.vmDocument.objectName -split '/'
    $ownerId = $db.vmDocument.objectId.entity.sqlEntity.ownerId
    $dbId = $db.vmDocument.objectId.entity.id

    ### handle log replay
    $versionNum = 0
    $validLogTime = $False
    $useLogTime = $False
    $latestUsecs = 0
    $oldestUsecs = 0

    $dbVersions = $db.vmDocument.versions

    if ($logTime -or $latest -or $noStop){
        if($logTime){
            $logUsecs = dateToUsecs $logTime
            $logUsecsDayStart = [int64] (dateToUsecs (get-date $logTime).Date) 
            $logUsecsDayEnd = [int64] (dateToUsecs (get-date $logTime).Date.AddDays(1).AddSeconds(-1))
        }elseif($latest -or $noStop){
            $logUsecsDayStart = [int64]( dateToUsecs (get-date).AddDays(-3))
            $logUsecsDayEnd = [int64]( dateToUsecs (get-date))
        }
        
        foreach ($version in $dbVersions) {
            $snapshotTimestampUsecs = $version.snapshotTimestampUsecs
            $oldestUsecs = $snapshotTimestampUsecs
            $timeRangeQuery = @{
                "endTimeUsecs"       = $logUsecsDayEnd;
                "protectionSourceId" = $dbId;
                "environment"        = "kSQL";
                "jobUids"            = @(
                    @{
                        "clusterId"            = $db.vmDocument.objectId.jobUid.clusterId;
                        "clusterIncarnationId" = $db.vmDocument.objectId.jobUid.clusterIncarnationId;
                        "id"                   = $db.vmDocument.objectId.jobUid.objectId
                    }
                );
                "startTimeUsecs"     = $logUsecsDayStart
            }
            $pointsForTimeRange = api post restore/pointsForTimeRange $timeRangeQuery
            if($pointsForTimeRange.PSobject.Properties['timeRanges']){
                # log backups available
                foreach($timeRange in $pointsForTimeRange.timeRanges){
                    $logStart = $timeRange.startTimeUsecs
                    $logEnd = $timeRange.endTimeUsecs
                    if($latestUsecs -eq 0){
                        $latestUsecs = $logEnd - 1000000
                    }
                    if($latest -or $noStop){
                        $logUsecs = $logEnd - 1000000
                    }
                    if(($logUsecs - 1000000) -le $snapshotTimestampUsecs -or $snapshotTimestampUsecs -ge ($logUsecs + 1000000)){
                        $validLogTime = $True
                        $useLogTime = $False
                        break
                    }elseif($logStart -le $logUsecs -and $logUsecs -le $logEnd -and $logUsecs -ge ($snapshotTimestampUsecs - 1000000)) {
                        $validLogTime = $True
                        $useLogTime = $True
                        break
                    }
                }
            }else{
                # no log backups available
                foreach($snapshot in $pointsForTimeRange.fullSnapshotInfo){
                    if($latestUsecs -eq 0){
                        $latestUsecs = $snapshotTimestampUsecs
                    }
                    if($logTime){
                        if($snapshotTimestampUsecs -le ($logUsecs + 60000000)){
                            $validLogTime = $True
                            $useLogTime = $False
                            break
                        }
                    }elseif($latest -or $noStop) {
                        $validLogTime = $True
                        $useLogTime = $False
                        break
                    }
                }
            }
            if($latestUsecs -eq 0){
                $latestUsecs = $oldestUsecs
            }
            if(! $validLogTime){
                $versionNum += 1
            }else{
                break
            }
        }
        if(! $validLogTime){
            Write-Host "log time is out of range" -ForegroundColor Yellow        
            Write-Host "Valid range is $(usecsToDate $oldestUsecs) to $(usecsToDate $latestUsecs)"
            break
        }
    }

    ### create new clone task (RestoreAppArg Object)
    $taskDate = (get-date).ToString('yyyy-MM-dd_HH-mm-ss')
    $taskName = "$($sourceServer)_$($targetServer)_$($sourceDBname)_$($taskDate)"
    $restoreTask = @{
        'name' = $taskName;
        'action' = 'kRecoverApp';
        'restoreAppParams' = @{
            'type' = 3;
            'ownerRestoreInfo' = @{
                "ownerObject" = @{
                    "jobUid" = $db.vmDocument.objectId.jobUid;
                    "jobId" = $db.vmDocument.objectId.jobId;
                    "jobInstanceId" = $dbVersions[$versionNum].instanceId.jobInstanceId;
                    "startTimeUsecs" = $dbVersions[$versionNum].instanceId.jobStartTimeUsecs;
                    "entity" = @{
                        "id" = $ownerId
                    }
                }
                'ownerRestoreParams' = @{
                    'action' = 'kRecoverVMs';
                    'powerStateConfig' = @{}
                };
                'performRestore' = $false
            };
            'restoreAppObjectVec' = @(
                @{
                    "appEntity" = $db.vmDocument.objectId.entity;
                    'restoreParams' = @{
                        'sqlRestoreParams' = @{
                            'captureTailLogs' = $false;
                            'secondaryDataFileDestinationVec' = @();
                            'alternateLocationParams' = @{};
                        };
                    }
                }
            )
        }
    }

    if($noRecovery){
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams.withNoRecovery = $True
    }

    ### if not restoring to original server/DB
    $targetDBname = "$prefix$sourceDBname$suffix"

    if($targetDBname -ne $sourceDBname -or $targetServer -ne $sourceServer -or $differentInstance -or $forceAlternateLocation){
        $secondaryFileLocation = @()
        if($useSourcePaths){
            if($importFileInfo){
                $importedDBFileInfo = $importedFileInfo | Where-Object {$_.name -eq $db.vmDocument.objectName}
                if($importedDBFileInfo){
                    $dbFileInfoVec = $importedDBFileInfo.fileInfo                    
                }else{
                    Write-Host "No imported file info found for $($db.vmDocument.objectName)"
                    exit 1
                }
            }else{
                $dbFileInfoVec = $db.vmDocument.objectId.entity.sqlEntity.dbFileInfoVec
            }
            $mdfFolderFound = $False
            $ldfFolderFound = $False
            foreach($datafile in $dbFileInfoVec){
                $path = $datafile.fullPath.subString(0, $datafile.fullPath.LastIndexOf('\'))
                $fileName = $datafile.fullPath.subString($datafile.fullPath.LastIndexOf('\') + 1)
                if($datafile.type -eq 0){
                    if($mdfFolderFound -eq $False){
                        $mdfFolder = $path
                        $mdfFolderFound = $True
                    }else{
                        $secondaryFileLocation = @($secondaryFileLocation + @{'filePattern' = $datafile.fullPath; 'targetDirectory' = $path})
                    }
                }
                if($datafile.type -eq 1){
                    if($ldfFolderFound -eq $False){
                        $ldfFolder = $path
                        $ldfFolderFound = $True
                    }
                }
            }
        }
        if($mdfFolderFound -eq $False){
            Write-Host "No path information found for $($db.vmDocument.objectName)" -ForegroundColor Yellow
            exit 1
        }
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['dataFileDestination'] = $mdfFolder;
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['logFileDestination'] = $ldfFolder;
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['secondaryDataFileDestinationVec'] = $secondaryFileLocation;
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['newDatabaseName'] = $targetDBname;
        # Write-Host "** Restoring $targetDBName to $mdfFolder"
    }

    ### apply log replay time
    if($useLogTime -eq $True){
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['restoreTimeSecs'] = $([int64]($logUsecs/1000000))
        $restoreTime = usecsToDate $logUsecs
    }else{
        $restoreTime = usecsToDate $dbVersions[$versionNum].instanceId.jobStartTimeUsecs
    }

    if($noStop -and $useLogTime){
        # replay logs to one hour in the future to ensure no STOPAT
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['restoreTimeSecs'] = (3600 + (datetousecs (Get-Date)) / 1000000)
    }

    ### search for target server
    if($targetServer -ne $sourceServer -or $differentInstance){
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams['targetHost'] = $targetEntity.appEntity.entity;
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams['targetHostParentSource'] = @{ 'id' = $targetEntity.appEntity.entity.parentId }
        if($targetInstance){
            $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['instanceName'] = $targetInstance
        }else{
            $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['instanceName'] = 'MSSQLSERVER'
        }
    }else{
        $targetServer = $sourceServer
    }

    ### overWrite existing DB
    if($overWrite){
        $restoreTask.restoreAppParams.restoreAppObjectVec[0].restoreParams.sqlRestoreParams['dbRestoreOverwritePolicy'] = 1
    }

    ### execute the recovery task (post /recoverApplication api call)
    $response = api post /recoverApplication $restoreTask

    if($targetInstance -eq ''){
        $targetInstance = 'MSSQLSERVER'
    }

    if($response){
        "Restoring $sourceInstance/$sourceDBname to $targetServer/$targetInstance/$targetDBname (Point in time: $restoreTime)"
    }

    if($wait -or $progress){
        $lastProgress = -1
        $taskId = $response.restoreTask.performRestoreTaskState.base.taskId
        $finishedStates = @('kSuccess','kFailed','kCanceled','kFailure')
        while($True){
            $status = (api get /restoretasks/$taskId).restoreTask.performRestoreTaskState.base.publicStatus
            if($progress){
                $progressMonitor = api get "/progressMonitors?taskPathVec=restore_sql_$($taskId)&includeFinishedTasks=true&excludeSubTasks=false"
                try{
                    $percentComplete = $progressMonitor.resultGroupVec[0].taskVec[0].progress.percentFinished
                    if($percentComplete -gt $lastProgress){
                        "{0} percent complete" -f [math]::Round($percentComplete, 0)
                        $lastProgress = $percentComplete
                        if($percentComplete -eq 100){
                            break
                        }
                    }
                }catch{
                    $percentComplete = 0
                    "{0} percent complete" -f [math]::Round($percentComplete, 0)
                    $lastProgress = 0
                }

            }
            if ($status -in $finishedStates){
                break
            }
            sleep 5
        }
        $status = (api get /restoretasks/$taskId).restoreTask.performRestoreTaskState.base.publicStatus
        "restore ended with $($status.substring(1))"
    }
}

### restore databases
foreach($db in $dbresults){
    $dbname = $db.vmDocument.objectName
    if($allDBs -or $dbname -in $selectedDBs){
        $i, $n = $dbname -split '/'
        if($includeSystemDBs -or ($n -notin @('master', 'model', 'msdb', 'tempdb'))){
            if($showPaths){
                Write-Host "`n$dbname"
                $db.vmDocument.objectId.entity.sqlEntity.dbFileInfoVec | convertto-json -depth 99
                # $db.vmDocument.objectId.entity.sqlEntity.dbFileInfoVec | Format-Table -Property logicalName, @{l='Size (MiB)'; e={$_.sizeBytes / (1024 * 1024)}}, fullPath
            }else{
                restoreDB($db)
            }
        }else{
            Write-Host "Skipping System DB $dbname..." -ForegroundColor Cyan
        }
    }
}
exit 0
