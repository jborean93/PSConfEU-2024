# podman run --rm -it mcr.microsoft.com/azure-powershell pwsh
# Might have to run a few times after dealing with resources that rely on other resources
# Get-AzResource -ResourceGroupName PSConfEU | Remove-AzResource -Force -Verbose -ErrorAction Continue

#Requires -Module Az.Compute, Az.Network, Az.Resources

[CmdletBinding()]
param (
    $ResourceGroup = 'PSConfEU',
    [ArgumentCompletions('francecentral', 'germanywestcentral', 'northeurope', 'westeurope', 'uksouth')]
    $Location = 'westeurope',
    $Count = 1
)

$ErrorActionPreference = 'Stop'

$nsgName = "$ResourceGroup-$Location-nsg"
$vnetName = "$ResourceGroup-$Location-vnet"
$subnetName = "$ResourceGroup-$Location-subnet"

Connect-AzAccount -UseDeviceAuthentication | Out-Null

Write-Host "Configuring Resource Group '$ResourceGroup' in '$Location'"
$rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    $rg = New-AzResourceGroup -Name $ResourceGroup -Location $Location
}

$priority = 100
$nsgRules = foreach ($info in @(
    @{
        Name = 'rdp-rule'
        Description = 'Allow RDP'
        Port = 3389
    }
    @{
        Name = 'winrm-rule'
        Description = 'Allow WinRM'
        Port = 5985
    }
)) {
    $ruleConfig = @{
        Name = $info.Name
        Description = $info.Description
        Access = 'Allow'
        Protocol = 'Tcp'
        Direction = 'Inbound'
        Priority = $priority++
        SourceAddressPrefix = 'Internet'
        SourcePortRange = '*'
        DestinationAddressPrefix = '*'
        DestinationPortRange = $info.Port
    }
    New-AzNetworkSecurityRuleConfig @ruleConfig
}

Write-Host "Configuring Network Security Group '$nsgName'"
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $nsgName -ErrorAction SilentlyContinue
if (-not $nsg) {
    $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Location $Location -Name $nsgName -SecurityRules $nsgRules
}

Write-Host "Configuring Network Subnet '$subnetName'"
$subnet = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.0.0.0/24" -NetworkSecurityGroup $nsg
$vnet = Get-AzVirtualNetwork -Name $vnetName
if (-not $vnet) {
    $vnet = New-AzVirtualNetwork -Force -Name $vnetName -ResourceGroupName $ResourceGroup -Location $Location -AddressPrefix "10.0.0.0/16" -Subnet $subnet
}
$subnetId = $vnet.Subnets[0].Id

1..$Count | ForEach-Object -Parallel {
    $ResourceGroup = $using:ResourceGroup
    $Location = $using:Location
    $subnetId = $using:subnetId
    $id = [Guid]::NewGuid().Guid

    Write-Host "Creating VM Public IP '$ResourceGroup-pubip-$id' and Network Interface '$ResourceGroup-nic-$id'"
    $pubip = New-AzPublicIpAddress -Force -Name "$ResourceGroup-pubip-$id" -ResourceGroupName $ResourceGroup -Location $Location -AllocationMethod Static
    $nic = New-AzNetworkInterface -Force -Name "$ResourceGroup-nic-$id" -ResourceGroupName $ResourceGroup -Location $Location -SubnetId $subnetId -PublicIpAddressId $pubip.Id
    $nicId = $nic.Id

    $computerName = $id.Replace("-", "").Substring(0, 14)
    $adminUsername = "ansible"
    $adminPassword = [Guid]::NewGuid().Guid
    $adminCredential = [pscredential]::new($adminUsername, (ConvertTo-SecureString -AsPlainText -Force -String $adminPassword))
    $vmName = "PSConfEU-Ansible-$id"

    $vmConfig = New-AzVMConfig -VMName $vmName -VMSize Standard_D2_v3 |
        Set-AzVmOperatingSystem -Windows -Credential $adminCredential -ComputerName $computerName |
        Set-AzVMSourceImage -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2022-DataCenter -Version Latest |
        Set-AzVMBootDiagnostic -Disable |
        Add-AzVMNetworkInterface -Id $nicId -DeleteOption Delete

    Write-Host "Creating VM '$vmName' with Public IP '$($pubip.IPAddress)' and Admin Password '$adminPassword'"
    $null = New-AzVM -ResourceGroupName $ResourceGroup -Location $Location -Vm $vmConfig
    Write-Host "VM '$vmName' created"

    [PSCustomObject]@{
        IPAddress = $pubip.IPAddress
        ComputerName = $computerName
        AdminUsername = $adminUsername
        AdminPassword = $adminPassword
    }
} | ConvertTo-Json | Set-Content "VMDetails-$(Get-Date -Format HHmmss).json"
