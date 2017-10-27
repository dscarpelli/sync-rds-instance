#!/bin/bash

###################################
# Restores $targetdb RDS instance
# from snapshot of $sourcedb if 
# it is < $fresh old.  Assumes AWS
# CLI is installed and env vars are
# populated.
#
# 2017 - Don Scarpelli
###################################

fresh=$(date -d"-1 days" +%s)   # Desired snapshot freshness
sourcedb="prod-rds-instance"    # DB Instance ID of source instance
targetdb="dev-rds-instance"     # DB Instance ID of target instance  

### Modify values as necessary, see:
### http://docs.aws.amazon.com/cli/latest/reference/rds/restore-db-instance-from-db-snapshot.html
### For additional settings, uncomment and modify the section after restore_snap on line ~75
restore_snap () {
/usr/local/bin/aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier $targetdb \
  --db-snapshot-identifier $restoresnap \
  --db-instance-class db.m4.large \
  --db-subnet-group-name default-vpc-1234567 \
  --multi-az \
  --no-publicly-accessible \
  --auto-minor-version-upgrade \
  --tags Key=Tier,Value=dev \
  --storage-type gp2 >/dev/null 2>&1

while true; do
  status=$(/usr/local/bin/aws rds describe-db-instances --db-instance-identifier $targetdb --output json | /usr/bin/python -c "import sys, json; print json.load(sys.stdin)['DBInstances'][0]['DBInstanceStatus']")
  if [[ "$status" == "available" ]]; then
    break
  fi
  sleep 60
done
}

# Identify snapshot ID to restore from, or fail
restoresnap=""
while read -r snap; do
  mtime=$(echo $snap | awk '{print $2}')
  mtime=$(date -d"$mtime" +%s || /bin/echo bad)
  if [[ "$mtime" == "bad" ]]; then
    continue
  fi
  if [[ $mtime -lt $fresh ]]; then
    restoresnap=$(echo $snap | awk '{print $1}')
  fi
done < <(/usr/local/bin/aws rds describe-db-snapshots --db-instance-identifier $sourcedb --output text | awk '{print $6, $(NF-4)}')

if [[ -z "$restoresnap" ]]; then
  echo "Sync failed - No valid snapshot found"
  exit 1
fi

echo "Renaming $targetdb"
/usr/local/bin/aws rds modify-db-instance \
  --db-instance-identifier $targetdb \
  --new-db-instance-identifier ${targetdb}-previous \
  --apply-immediately >/dev/null 2>&1

# Wait for instance renaming process to complete
while true; do
  /usr/local/bin/aws rds describe-db-instances --db-instance-identifier $targetdb >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    break
  fi
  sleep 30
done

echo "Restoring $targetdb from $restoresnap"
restore_snap

### Optional: Modify things not set correctly during restore, e.g. parameter group
#/usr/local/bin/aws rds modify-db-instance \
#  --db-instance-identifier $targetdb \
#  --db-parameter-group-name dev \
#  --copy-tags-to-snapshot \
#  --monitoring-role-arn arn:aws:iam::12345678910:role/example-monitoring-role \
#  --monitoring-interval 60 \
#  --apply-immediately >/dev/null 2>&1

### Required if setting the db-parameter-group-name above
#while true; do
#  status=$(/usr/local/bin/aws rds describe-db-instances --db-instance-identifier $targetdb --output json | /usr/bin/python -c "import sys, json; print json.load(sys.stdin)['DBInstances'][0]['DBParameterGroups'][0]['ParameterApplyStatus']")
#  if [[ "$status" == "pending-reboot" ]]; then
#    break
#  fi
#  sleep 15
#done
#/usr/local/bin/aws rds reboot-db-instance --db-instance-identifier $targetdb >/dev/null 2>&1

/usr/local/bin/aws rds delete-db-instance \
  --db-instance-identifier ${targetdb}-previous \
  --skip-final-snapshot >/dev/null 2>&1

echo "Sync completed"
