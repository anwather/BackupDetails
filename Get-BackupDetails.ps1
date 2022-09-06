Param([string]$WorkspaceId)

$subscriptionQuery = @'
resourcecontainers
| where type == "microsoft.resources/subscriptions"
| project subscriptionId, name
'@

$subscriptionResults = Search-AzGraph -Query $subscriptionQuery -First 1000

$subscriptionHash = @{}

$subscriptionResults | Foreach-Object {
    $subscriptionHash.Add($_.subscriptionId, $_.name)
}

$backupQuery = @'
resources
| where type == 'microsoft.compute/virtualmachines'
| extend powerState = tostring(properties.extended.instanceView.powerState.displayStatus)
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
| project virtualMachineId=['id'], recoveryServicesVault = id1,backedUp,environment=tags["Environment"],location, powerState
'@

$backupResults = Search-AzGraph -Query $backupQuery -First 1000

$vaultStorageTypes = @{}

($backupResults | Where backedup -eq "true" | Select-Object -Unique recoveryServicesVault).recoveryServicesVault | ForEach-Object {
    $subscription = $_.Split('/')[2]
    $resourceGroupName = $_.Split('/')[4]
    $rsName = $_.Split('/')[-1]
    $uri = "https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.RecoveryServices/vaults/{2}/backupstorageconfig/vaultstorageconfig?api-version=2018-12-20" -f $subscription, $resourceGroupName, $rsName
    $storageType = ((Invoke-AzRestMethod -Uri $uri).Content | ConvertFrom-Json).properties.storageType
    $vaultStorageTypes.Add($_, $storageType)
}

$backupResults | ForEach-Object {
    $_ | Add-Member -MemberType NoteProperty -Name VM_Subscription -Value $subscriptionHash[$_.virtualMachineId.Split("/")[2]] -Force
    $_ | Add-Member -MemberType NoteProperty -Name VM_Name -Value $_.virtualMachineId.Split("/")[-1] -Force
}

$backupResults | Foreach-Object {
    if ($_.backedUp -eq "true") {
        $_ | Add-Member -MemberType NoteProperty -Name StorageType -Value $vaultStorageTypes[$_.recoveryServicesVault] -Force
        $_ | Add-Member -MemberType NoteProperty -Name RSV_Subscription -Value $subscriptionHash[$_.recoveryServicesVault.Split("/")[2]] -Force
    }
}

$storageQuery = @'
AzureDiagnostics
| where OperationName == 'StorageAssociation'
| project StorageConsumedInMBs_s,TimeGenerated,VirtualMachine=strcat_array(split(ProtectedContainerUniqueId_s,";", 4),'')
| extend StorageConsumedInGBs= round(todouble(StorageConsumedInMBs_s)/1024,2)
| summarize StorageConsumedInGBs=avg(StorageConsumedInGBs) by bin(TimeGenerated,1d), VirtualMachine
| project TimeGenerated,VirtualMachine,StorageConsumedInGBs
'@

$storageResults = Invoke-AzOperationalInsightsQuery -Query $storageQuery -WorkspaceId $workspaceId

$storageHash = @{}

($storageResults.Results -as [Array]) | Foreach-Object {
    if (!($storageHash.ContainsKey($_.VirtualMachine))) {
        $storageHash.Add($_.VirtualMachine, [double]$_.StorageConsumedInGBs)
    }
}

function ValidateEnvironment {
    Param($StorageType, $Environment)
    switch ($StorageType) {
        "LocallyRedundant" { if ($Environment -notmatch "DR$|-NONPROD$") { return $true } else { return $false } }
        "GeoRedundant" { if ($Environment -notmatch "-PROD$") { return $true } else { return $false } }
        "ZoneRedundant" { if ($Environment -notin $prEnvironments) { return $true } else { return $false } }
        default { return $true }
    }
}

$backupResults | Foreach-Object {
    if ($_.backedUp -eq "true") {
        $_ | Add-Member -MemberType NoteProperty -Name StorageConsumedInGBs -Value $storageHash[$_.VM_Name] -Force
        $_ | Add-Member -MemberType NoteProperty -Name Validate -Value (ValidateEnvironment -StorageType $_.StorageType -Environment $_.RSV_Subscription) -Force
    } 
}


$backupResults | Export-Csv output.csv -Force

