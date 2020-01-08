param($Request)

$csirtsubnetname = "csirt-subnet"
$csirtsubnetnsg = "csirt-subnet-nsg"
$csirtsubnetprefix = ""
$externalip = ""
$siftuser = "siftuser"
$siftvmpassword = $env:siftvmpassword # Set as a variable in the Azure Function
$sshPublicKey = $env:siftvmsshkey # Set as a variable in the Azure Function
$SIFTimageResourceGroup = "SIFT"
$SIFTimagename = "sift-workstation-image-v1.0"

$WebhookData = $Request.rawbody

$WebhookBody = (ConvertFrom-Json -InputObject $WebhookData)

function Get-AzVMVnet {
    param([string]$vmname)

    $vm = Get-AzVM -Name $vmname
    $nic = Get-AzNetworkInterface -Name ($vm.NetworkProfile.NetworkInterfaces[0].Id.Split('/') | Select-Object -Last 1)

    $nicSnId = $nic.IpConfigurations[0].Subnet.Id

    $vnets= Get-AzVirtualNetwork
    foreach ($vnet in $vnets){
        $vnetSnId = $vnet.Subnets.Id
        if ($vnetSnId -eq $nicSnId){
            $vnetName = $vnet.Name
        }
    }
    return (Get-AzVirtualNetwork -Name $vnetname)
}

function New-CsirtNSG {
    param([String]$vmname)

    Write-Output "Create CSIRT NSG"

    if ($null -eq (Get-AzNetworkSecurityGroup -name $csirtsubnetnsg)){
        $vnet = Get-AzVMVnet $vmname
        $resourcegroup = $vnet.ResourceGroupName
        $location = $vnet.Location
    
        $rule1 = New-AzNetworkSecurityRuleConfig -Name AllowSSH -Description "Allow SSH" -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix "$externalip/32" -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
        $rule2 = New-AzNetworkSecurityRuleConfig -Name AllowRDP -Description "Allow RDP" -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 -SourceAddressPrefix "$externalip/32" -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389
        $rule3 = New-AzNetworkSecurityRuleConfig -Name DenyAllInbound -Description "DenyAllInbound" -Access Deny -Protocol * -Direction Inbound -Priority 120 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange *
        $rule4 = New-AzNetworkSecurityRuleConfig -Name DenyAllOutbound -Description "DenyAllOutbound" -Access Deny -Protocol * -Direction Outbound -Priority 100 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange *
        New-AzNetworkSecurityGroup -ResourceGroupName $resourcegroup -Location $location -Name $csirtsubnetnsg -SecurityRules $rule1,$rule2,$rule3,$rule4 -Force
    }else{
        Write-Output "CSIRT NSG exists"
    }
}

function New-CSIRTSubnet {
    param([String]$vmname)

    Write-Output "Create CSIRT Subnet"
 
    $vnet = Get-AzVMVnet $vmname
    $subnets = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet
    foreach ($subnet in $subnets){
        if ($subnet.name -eq $csirtsubnetname){
            Write-Output "CSIRT subnet exists"
            $exists = $true
        }
    }

    if (!($exists)){
        $nsg = Get-AzNetworkSecurityGroup -Name $csirtsubnetnsg
        Add-AzVirtualNetworkSubnetConfig -Name $csirtsubnetname -VirtualNetwork $vnet -AddressPrefix $csirtsubnetprefix -NetworkSecurityGroup $nsg | Set-AzVirtualNetwork
    }
}

function Move-AzVMtoCSIRTSubnet {
    param([string]$vmname)
 
    Write-Output "Move VM to CSIRT subnet"

    $vm = Get-AzVM -Name $vmname
    $nic = Get-AzNetworkInterface -Name ($vm.NetworkProfile.NetworkInterfaces[0].Id.Split('/') | Select-Object -Last 1)
    $vnet = Get-AzVMVnet $vmname
    $csirtsubnet = Get-AzVirtualNetworkSubnetConfig -Name $csirtsubnetname -VirtualNetwork $vnet

    $nic.IpConfigurations[0].Subnet.Id = $csirtsubnet.Id
    Set-AzNetworkInterface -NetworkInterface $nic
}

function New-SIFTWorkstationVM {
    param([String]$vmname)

    Write-Output "Create SIFT Workstation"

    $vnet = Get-AzVMVnet $vmname
    $vnetName = $vnet.Name
    $name = "SIFT-Workstation-$vnetName" 
    $resourcegroup = $vnet.ResourceGroupName
    $location = $vnet.Location
    $csirtsubnet = Get-AzVirtualNetworkSubnetConfig -Name $csirtsubnetname -VirtualNetwork $vnet
    $imageid = $SIFTimageid

    if ($null -eq (Get-AzVm -name $name)){
        $securePassword = ConvertTo-SecureString $siftvmpassword -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($siftuser, $securePassword)

        $pip = New-AzPublicIpAddress `
        -Name "$name-pip" `
        -ResourceGroupName $resourcegroup `
        -Location $location `
        -AllocationMethod Dynamic `

        $nic = New-AzNetworkInterface `
        -Name "$name-nic" `
        -ResourceGroupName $resourcegroup `
        -Location $location `
        -SubnetId $csirtsubnet.Id `
        -PublicIpAddressId $pip.Id `

        $vmConfig = New-AzVMConfig `
        -VMName $name `
        -VMSize "Standard_B1ms" | `
        Set-AzVMOperatingSystem `
        -Linux `
        -ComputerName $name `
        -Credential $cred `
        -DisablePasswordAuthentication | `
        Set-AzVMSourceImage `
        -Id $imageid | `
        Set-AzVMBootDiagnostic `
        -Disable | `
        Add-AzVMNetworkInterface `
        -Id $nic.Id

        # Configure the SSH key
        Add-AzVMSshPublicKey `
        -VM $vmconfig `
        -KeyData $sshPublicKey `
        -Path "/home/$siftuser/.ssh/authorized_keys"

        New-AzVM `
        -ResourceGroupName $resourcegroup `
        -Location $location -VM $vmConfig
   }else{
        Write-Output "SIFT Workstation exists"
    }

}

function New-VMSnapshot {
    param([String]$vmname)

    $vm = Get-AzVM -name $vmname
    $location = $vm.Location
    $resourcegroup = $vm.ResourceGroupName
    $snapshotName = $vm.name + "-snapshot"

    $snapshot = New-AzSnapshotConfig -SourceUri $vm.StorageProfile.OsDisk.ManagedDisk.Id -Location $location -CreateOption copy
    New-AzSnapshot -Snapshot $snapshot -SnapshotName $snapshotName -ResourceGroupName $resourcegroup
}

if ($WebhookBody)
{
    $AffectedItems = $WebhookBody.data.alertcontext.AffectedConfigurationItems

    foreach ($item in $AffectedItems){
        $ItemArray = $item.Split("/")
        $SubId = ($ItemArray)[2]
        $ResourceGroupName = ($ItemArray)[4]
        $ResourceType = ($ItemArray)[6] + "/" + ($ItemArray)[7]
        $ResourceName = ($ItemArray)[-1]
        $SIFTimageid = "/subscriptions/$subid/resourceGroups/$SIFTimageResourceGroup/providers/Microsoft.Compute/images/$SIFTimagename"

        Write-Output $SubId
        Write-Output $ResourceGroupName
        Write-Output $ResourceType
        Write-Output $ResourceName

        if ($ResourceType -eq "Microsoft.Compute/virtualMachines"){
            Write-Output "Create VM Disk Snapshot"
            New-VMSnapshot $ResourceName            

            Write-Output "Start CSIRT NSG Creation - $ResourceName"
            New-CSIRTNSG $ResourceName
        
            Write-Output "Start CSIRT Subnet Creation - $ResourceName"
            New-CSIRTSubnet $ResourceName
    
            Write-Output "Start VM move - $ResourceName"
            Move-AzVMtoCSIRTSubnet $ResourceName

            Write-Output "Start SIFT Workstation Creation - $ResourceName"
            New-SIFTWorkstationVM $ResourceName
        }else{
            Write-Output "$ResourceName is not a virtual Machine"
        }
    }
}else{
    Write-Output "No event data available"
}
