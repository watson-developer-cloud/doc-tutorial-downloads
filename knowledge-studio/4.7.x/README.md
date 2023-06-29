# wks-scripts
Utility script files for WKS (on CP4D)

The purpose of utility script files is system backup/restore of CP4D instance, NOT individual WKS artifacts (workspace, e.g.) backup/restore. 

Please use the `backup` for the same WKS instance. Restore a `backup` from different instance will cause errors.

Any modifications that have been made after the previous `backup` will be replaced with backup contents by `restore`. For example:
- WKS workspace that was created after the previous `backup` will be deleted.
- Changes made on WKS workspaces contents after the previous `backup` will be replaced with backup contents.

backup/restore scripts do backup/restore data in the following databases of WKS in the order:
  1. MongoDB
  2. PostgreSQL
  3. S3
  
<b>NOTE</b> Users should not access to WKS during backup/restore because WKS will be deactivated (All deactivated pods will be reactivated after backup/restore) 

# Deactivate and Reactivate Knowledge Studio
   ## Note: You don't need to deactivate/reactivate when you run the all-backup-restore.sh script because the script handles the process.
- Deactivate Knowledge Studio
    - Make sure that no training and evaluation processes are running. You can check job status with the following command:
        - `oc -n NAMESPACE get jobs`
        -  raining jobs of Knowledge Studio are named in the format wks-train-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx, and evaluation jobs are named in the format wks-batch-apply-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx. If the COMPLETIONS column of a training job reads 0/1, that job is still running. Wait until all of the training jobs finish.
    - Deactivate Knowledge Studio with the following command:
        - `oc -n NAMESPACE patch --type=merge wks wks -p '{"spec":{"global":{"quiesceMode":true}}}'`
    - Make sure no Knowledge Studio pods exist except datastore pods by the following command (this may takes few minutes):
        - `oc -n NAMESPACE get pod | grep -Ev 'minio|etcd|mongo|postgresql|gw-instance|Completed' | grep wks`

- Reactivate Knowledge Studio
    - Reactivate Knowledge Studio with the following command:
        - `oc -n NAMESPACE patch --type=merge wks wks -p '{"spec":{"global":{"quiesceMode":false}}}'`

# About backup/restore scripts
  ## all-backup-restore.sh [command] [releaseName] [backupDir] [-n namespace]
   ### Overall
   This script delegates operations of backup/restore to each database scripts (`mongodb-backup-restore.sh`, `postgresql-backup-restore.sh`, `s3-backup-restore.sh`). The order of getting backup/restore is MongoDB, PostgreSQL, S3. Besides, at the beginning of this script, scale down the number of pods to zero. At the end of this script, scale up the number of pods to the initial state. <b>We would recommend running `all-backup-restore.sh` rather than running each database scripts.</b>
    
   ### Prerequisite
    
   S3 (Minio) client (`mc` command) is required to run backup/restore scripts of S3/Minio. 
   Please verify that `mc` command is runnable by `type mc` command.
   Otherwise, scripts will download it from MinIO web site (`https://dl.min.io/`) during backup/restore.
    
   ### Arguments:
   - `[command]`: there are two modes:
       - `backup`: data of each database are saved into backup directories.
       - `restore`: data of each database are recovered by loading data from backup directories.
   - `[releaseName]`: release name. you can find it at prefix of pod name, e.g. `{release_name}-ibm-watson-ks-yyy-xxx`
       - In 2020 June release, `{release_name}` is always `wks`
   - `[backupDir]`: Backup data of MongoDB, PostgreSQL, S3 are stored respectively into these directories. Each database is also restored loading backup data from these directories:
       - `backup`: a new folder with timestamp `wks-backup-yyyymmdd_hhmmss` will be created under [backupDir]:
           - `[backupDir]/wks-backup-yyyymmdd_hhmmss/mongodb`
           - `[backupDir]/wks-backup-yyyymmdd_hhmmss/postgresql`
           - `[backupDir]/wks-backup-yyyymmdd_hhmmss/s3`
       - `restore`: please set [backupDir] with the name `wks-backup-yyyymmdd_hhmmss` and ensure that the fallowing folders are located within the directory:
           - `[backupDir]/mongodb`
           - `[backupDir]/postgresql`
           - `[backupDir]/s3` ( or `[backupDir]/minio` if the backup data is from previous version, such as 4.6.x or 4.5.x )
   - `[-n namespace]`: namespace where pods exist
       - default namespace is `zen` (if you do not change it) 
            
   ### Status
   Please verify that the success message is shown in console log when all scripts succeed.
   - `[SUCCESS] MongoDB,PostgreSQL,S3 (backup|restore)`

   Otherwise, some of scripts fail when the fail message is shown. <b>In this case, backup data is corrupted, so please do NOT use the corrupted backup data to restore.</b>
   - `[FAIL] MongoDB,PostgreSQL,S3 (backup|restore)`

 ## mongodb-backup-restore.sh [command] [releaseName] [backupDir] [-n namespace]
    
   Deactivate Knowledge Studio before backup/restore and Reactivate Knowledge Studio after backup/restore.
    
   ### Backup
   Get backup of MongoDB data
   1. Create remote temp file under mongoDB pod, and extract following data　`WKSDATA` `ENVDATA` `escloud_sbsep`.
   2. Copy `WKSDATA` `ENVDATA` `escloud_sbsep` to local `[backupDir]`.
   3. Remove remote temp file.
   ### Restore
   Restore the backed up data to MongoDB
   1. Create remote temp file under mongoDB pod
   2. Copy `WKSDATA` `ENVDATA` `escloud_sbsep` from local `[backupDir]` to remote temp file.
   3. Restore `WKSDATA` `ENVDATA` `escloud_sbsep` on remote temp file.
   4. Remove remote temp file.

 ## postgresql-backup-restore.sh [command] [releaseName] [backupDir] [-n namespace]

   Before backup/restore:
    
   Deactivate Knowledge Studio before backup/restore and Reactivate Knowledge Studio after backup/restore.
    
   ### Backup
   Get backup of the postgresql by getting data dump.
   1. Create a job for postgresql backup
   2. Dump the databases such as `jobq_{release_name_underscore}`, `model_management_api` and `model_management_api_v2`. The dump files will be named as its name with suffix `.custom`.
   3. Copy the dump files to local `[backupDir]`.
   4. Delete `.pgpass`

   ### Restore
   Restore the backup data to postgresql by putting data. Delete all existing databases.
   1. Create a job for postgresql restore
   2. Restore the databases (`jobq_{release_name_underscore}`, `model_management_api` and `model_management_api_v2`) by loading `.custom` files under `[backupDir]`.
   3. Delete `.pgpass`

## S3-backup-restore.sh [command] [releaseName] [backupDir] [-n namespace]

   Before backup/restore:
    
   Deactivate Knowledge Studio before backup/restore and Reactivate Knowledge Studio after backup/restore.
    
   ### Backup
   Get backup of S3 by getting snapshot.

   1. Configure S3 alias: `wks`
   2. Copy all data from `wks/wks-icp` to `{backupDir}`

   ### Restore
   Restore the backup data to S3.
   2. Configure S3 alias: `wks`
   3. Copy all data from `{backupDir}` to `wks/wks-icp`
