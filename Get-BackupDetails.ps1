$backupQuery = @'
resources
| where type == 'microsoft.compute/virtualmachines'
| join kind = leftouter    (
recoveryservicesresources
| where type == 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems'
| extend vmId = tostring(split(properties.virtualMachineId,'/')[-1])
| extend rsv = tostring(split(id,'/')[8])
| project vmId,rsv) on $left.name == $right.vmId
| join kind = leftouter  ( 
resources
| where type == 'microsoft.recoveryservices/vaults'
| extend rsv = name
| extend rsv = tostring(rsv)
| project rsv,id) on rsv
| extend backedUp = iif(rsv == '',"false","true")
| project virtualMachineId=['id'], recoveryServicesVault = id1,backedUp
'@

$backupResults = Search-AzGraph -Query $backupQuery

$vaultStorageTypes = @{}

($backupResults | Select-Object -Unique recoveryServicesVault).recoveryServicesVault | ForEach-Object {
    $subscription = $_.Split('/')[2]
    $resourceGroupName = $_.Split('/')[4]
    $rsName = $_.Split('/')[-1]
    $uri = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.RecoveryServices/vaults/{2}/backupstorageconfig/vaultstorageconfig?api-version=2018-12-20" -f $subscription, $resourceGroupName, $rsName
    $storageType = ((Invoke-AzRestMethod -Uri $uri).Content | ConvertFrom-Json).properties.storageType
    $vaultStorageTypes.Add($_, $storageType)
}

$backupResults | Foreach-Object {
    if ($_.backedUp) {
        $_ | Add-Member -MemberType NoteProperty -Name StorageType -Value $vaultStorageTypes[$_.recoveryServicesVault]
    }
}

