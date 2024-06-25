# podman run --rm -it mcr.microsoft.com/azure-powershell pwsh

#Requires -Module Az.Compute, Az.Network, Az.Resources

[CmdletBinding()]
param (
    $ResourceGroup = 'PSConfEU',
    $Location = 'westeurope',
    $Count = 1
)

$nsgName = "$ResourceGroup-nsg"
$vnetName = "$ResourceGroup-vnet"

Connect-AzAccount -UseDeviceAuthentication

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
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $nsgName -ErrorAction SilentlyContinue
if (-not $nsg) {
    $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Location $Location -Name $nsgName -SecurityRules $nsgRules
}

$subnet = New-AzVirtualNetworkSubnetConfig -Name "$ResourceGroup-subnet" -AddressPrefix "10.0.0.0/24" -NetworkSecurityGroup $nsg
$vnet = Get-AzVirtualNetwork -Name $vnetName
if (-not $vnet) {
    $vnet = New-AzVirtualNetwork -Force -Name  -ResourceGroupName $ResourceGroup -Location $Location -AddressPrefix "10.0.0.0/16" -Subnet $subnet
}
$subnetId = $vnet.Subnets[0].Id

1..$Count | ForEach-Object -Parallel {
    $ResourceGroup = $using:ResourceGroup
    $Location = $using:Location
    $subnetId = $using:subnetId
    $id = [Guid]::NewGuid().Guid

    $pubip = New-AzPublicIpAddress -Force -Name "$ResourceGroup-pubip-$id" -ResourceGroupName $ResourceGroup -Location $Location -AllocationMethod Static
    $nic = New-AzNetworkInterface -Force -Name "$ResourceGroup-nic-$id" -ResourceGroupName $ResourceGroup -Location $Location -SubnetId $subnetId -PublicIpAddressId $pubip.Id
    $nicId = $nic.Id

    $computerName = $id.Replace("-", "").Substring(0, 14)
    $adminUsername = "ansible"
    $adminPassword = [Guid]::NewGuid().Guid
    $adminCredential = [pscredential]::new($adminUsername, (ConvertTo-SecureString -AsPlainText -Force -String $adminPassword))

    $vmConfig = New-AzVMConfig -VMName "PSConfEU-Ansible-$id" -VMSize Standard_D2_v3 |
        Set-AzVmOperatingSystem -Windows -Credential $adminCredential -ComputerName $computerName |
        Set-AzVMSourceImage -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2022-DataCenter -Version Latest |
        Add-AzVMNetworkInterface -Id $nicId -DeleteOption Delete

    $null = New-AzVM -ResourceGroupName $ResourceGroup -Location $Location -Vm $vmConfig

    [PSCustomObject]@{
        IPAddress = $pubip.IPAddress
        ComputerName = $computerName
        AdminUsername = $adminUsername
        AdminPassword = $adminPassword
    }
} | ConvertTo-Json | Set-Content "VMDetails-$(Get-Date -Format HHmmss).json"
