# Manage Policies Using Python

Warning: this code is provided on a best effort basis and is not in any way officially supported or sanctioned by Cohesity. The code is intentionally kept simple to retain value as example code. The code in this repository is provided as-is and the author accepts no liability for damages resulting from its use.

This script lists or modified protection policies. The script is a work in progress and currently performs the following acttions:

* List Policies: shows local, replica and archival frequencies and retentions
* Add a Replica
* Delete a Replica

In the future, changing base and extended retentions, and adding and deleting archival targets will be added. All other features will be considered upon request.

Note: this script is written for Cohesity 6.5.1 and later.

## Download the script

You can download the scripts using the following commands:

```bash
# download commands
curl -O https://raw.githubusercontent.com/bseltz-cohesity/scripts/master/python/policyTool/policyTool.py
curl -O https://raw.githubusercontent.com/bseltz-cohesity/scripts/master/python/pyhesity.py
chmod +x policyTool.py
# end download commands
```

## Components

* policyTool.py: the main powershell script
* pyhesity.py: the Cohesity REST API helper module

Place both files in a folder together and run the main script like so:

To list policies:

```bash
./policyTool.py -v mycluster \
                -u myuser \
                -d mydomain.net
```

To list a specific policy:

```bash
./policyTool.py -v mycluster \
                -u myuser \
                -d mydomain.net \
                -p 'my policy'
```

To add a replica that replicates after every run with 31 day retention:

```bash
./policyTool.py -v mycluster \
                -u myuser \
                -d mydomain.net \
                -p 'my policy' \
                -a addreplica \
                -n myremotecluster \
                -r 31
```

To add a replica that replicates every two weeka with 3 month retention:

```bash
./policyTool.py -v mycluster \
                -u myuser \
                -d mydomain.net \
                -p 'my policy' \
                -a addreplica \
                -n myremotecluster \
                -f 2 \
                -fu weeks \
                -r 3 \
                -ru months
```

To delete that replica:

```bash
./policyTool.py -v mycluster \
                -u myuser \
                -d mydomain.net \
                -p 'my policy' \
                -a deletereplica \
                -n myremotecluster \
                -f 2 \
                -fu weeks 
```

To delete all replicas for a remote cluster:

```bash
./policyTool.py -v mycluster \
                -u myuser \
                -d mydomain.net \
                -p 'my policy' \
                -a deletereplica \
                -n myremotecluster \
                -all
```

## Parameters

* -v, --vip: DNS or IP of the Cohesity cluster to connect to
* -u, --username: username to authenticate to Cohesity cluster
* -d, --domain: (optional) domain of username, defaults to local
* -k, --useApiKey: (optional) use API key for authentication
* -pwd, --password: (optional) password of API key
* -p, --policyname: (optional) name of policy to focus on
* -n, --targetname: (optional) name of remote cluster or external target
* -f, --frequency: (optional) number of frequency units for schedule (default is 1)
* -fu, --frequencyunit: (optional) default is every run
* -r, --retention: (optional) number of retention units
* -ru, --retentionunit: (optional) default is days
* -a, --action: (optional) list, addreplica, deletereplica (default is list)
* -all, --all: (optional) delete all entries for the specified target