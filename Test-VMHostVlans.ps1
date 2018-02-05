<#
.SYNOPSIS
    Tests VLAN connectivity on a host.

.DESCRIPTION
    Gets all the VDSwitches and portgroups on a host configured with a VLAN and
    tests each VLAN by creating a test portgroup and vmkernel interface, assigning
    IP info from a CSV file and pinging the target IP addresses for each VLAN.
    If VLAN info isn't in the CSV file it is skipped.

.PARAMETER hostnames
    One or more hostnames to test VLANs on.  Hostnames can be comma separated or piped to the script from a file.

.PARAMETER vCenter
    The vCenter to connect to.  This can be left blank if the powercli session is already connected.

.PARAMETER csvFile
    The CSV file containing VLAN test info.  Defaults to .\TestVMHostVlans.csv
    CSV Format is: Vlan,TestIP,TestMask,TargetIP
    Vlan: the VLAN ID
    TestIP: the temporary/test IP address (source) to assign to the host
    TestMask: subnet mask for the test IP
    TargetIP: the target IP address (destination) it will attempt to ping

.PARAMETER vlan
    If specified, only this VLAN will be tested.  Allows for a single VLAN to be quickly tested without
    having to check all of them.

.PARAMETER output
    The name of the output file.  The results will be exported to CSV format and saved in this file.
    Defaults to "TestResults-<date.timestamp>.csv".

.EXAMPLE
    .\Test-VMHostVlans.ps1 -hostnames myesxhost.domain.com

    Test all vlans on a single host.

.EXAMPLE
    Get-Content Hostlist.txt | .\Test-VMHostVlans.ps1

    Test all vlans on all hosts listed in the file.

.EXAMPLE
    Get-Cluster VC-Clustername | Get-VMHost | .\TestVMHostVlans.ps1 -vlan 4

    Tests vlan 4 on all hosts in the cluster.

.NOTES
    Because this testing uses a vmkernel port, if the vCenter vlan is one of the vlans that it tests a host
    communication error (vmodl.fault.HostCommunication) will be reported when the test vmkernel port is
    changed from the vCenter vlan to the next vlan being tested.  This can safely be ignored since the actual
    management vmk does not have a communication issue, only the test vmk is affected.
#>
#Requires -modules VMware.VimAutomation.Core, VMware.VimAutomation.Vds
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
    [Alias('Name')]
    [string[]]$hostnames,
    $vCenter,
    $csvFile = ".\TestVMHostVlans.csv",
    $vlan,
    $output = "TestResults-$(Get-Date -format 'yyyy.MM.dd.HHmm').csv"
)
Begin {
    Import-Module VMware.VimAutomation.Core, VMware.VimAutomation.Vds
    If ($vCenter -ne $null) {
        Connect-VIServer $vCenter | Out-Null
    }

    If ((Test-Path $csvFile) -eq $true) {
        $vlanTestIPs = Import-Csv $csvFile
    }
    Else {
        Write-Host "The input CSV file '$csvFile' does not exist."
        Exit
    }
    $results = @()  # array containing the results of all tests
    $testPgPrefix = 'vlan-testing-psscript' # prefix for name of test portgroup
}

Process {
    Foreach ($hostname in $hostnames) {
        # Get the vmhost and esxcli for network diag (vmkping)
        # If there are multiple vcenter connections Get-VMHost can get multiple instances of the same host
        # Select -Unique filters out the duplicates
        $vmhost = Get-VMHost -Name $hostname | Select-Object -Unique
        $esxcli = get-esxcli -vmhost $vmhost
        If ($vmhost -eq $null -or $esxcli -eq $null) {
            Write-Host "Failed to get vmhost or esxcli for: $hostname"
            Continue  # continue with next host
        }

        # Get VDSwitches for the host
        Write-Host "Getting VDSwitches for $hostname"
        $vdswitches = Get-VDSwitch -VMHost $vmhost | Where 'Name' -NotMatch 'NFS'

        ForEach ($vdswitch in $vdswitches) {
            Write-Verbose "Beginning vdswitch: $vdswitch"
            $testPortgroup, $vmk = $null  # reset vdswitch variables

            # Portgroup names must be unique - get the ID of the current vdswitch and
            # append it to the test portgroup name
            $vdswitchId = $vdswitch.Id.Split('-')[-1]
            $testPgName = "$testPgPrefix-$vdswitchId"

            # If a vlan was specified, get the portgroup for that vlan.  Otherwise get all portgroups
            # configured with a vlan.
            If ($vlan -ne $null) {
                $portgroups = Get-VDPortgroup -VDSwitch $vdswitch | Where {$_.VlanConfiguration.VlanID -eq $vlan -and $_.Name -notmatch $testPgName}
            }
            Else {
                $portgroups = Get-VDPortgroup -VDSwitch $vdswitch | Where {$_.VlanConfiguration.Vlantype -eq "Vlan" -and $_.Name -notmatch $testPgName}
            }

            # Loop through each production portgroup and test the vlan using a test portgroup
            ForEach ($prodPortgroup in $portgroups) {
                Write-Verbose "Beginning portgroup: $portgroup"
                $status, $message = $null  # reset portgroup variables

                # Get production portgroup info to configure the test portgroup
                $vlanid = $prodPortgroup.VlanConfiguration.VlanID
                $prodPolicy = Get-VDUplinkTeamingPolicy -VDPortgroup $prodPortgroup
                $activeUplinks = $prodPolicy.ActiveUplinkPort
                $standbyUplinks = $prodPolicy.StandbyUplinkPort
                $unusedUplinks = $prodPolicy.UnusedUplinkPort
                $prodPortgroup = $null
                $prodPolicy = $null

                # Get test IP info from CSV
                $vlanInfo = $vlanTestIPs | Where 'Vlan' -eq $vlanid
                If ($vlanInfo -eq $null) {
                    Write-Host "Skipping vlan: $vlanid. No test IP in CSV file."

                    # Save results for this portgroup/vlan
                    $properties = [ordered]@{
                        'Hostname' = $hostname
                        'VDSwitch' = $vdswitch
                        'Uplink' = $null
                        'VLAN' = $vlanid
                        'Tx' = ''
                        'Rx' = ''
                        'Status' = 'No IP'
                        'Message' = 'No vlan info in CSV file.'
                    }
                    $results += New-Object -TypeName PSObject -Property $properties
                    Continue  # next portgroup/vlan
                }

                $testIP = $vlanInfo.TestIP
                $testMask = $vlanInfo.TestMask
                $targetIP = $vlanInfo.TargetIP
                Write-Host "Testing vlan: $vlanid, Source: $testIP, Destination: $targetIP"

                Try {
                    # Get/create test portgroup
                    $testPortgroup = Get-VDPortgroup -VDSwitch $vdswitch -Name $testPgName -ErrorAction SilentlyContinue
                    If ($testPortgroup -eq $null) {
                        Write-Verbose "Creating test portgroup on vdswitch: $vdswitch"
                        $testPortgroup = New-VDPortgroup -VDSwitch $vdswitch -Name $testPgName
                    }
                    # Configure vlan on test portgroup
                    Write-Verbose "Setting vlan $vlanid on test portgroup: $testPortgroup"
                    Set-VDVlanConfiguration -VDPortgroup $testPortgroup -VlanId $vlanid | Out-Null

                    # Get/create vmkernel interface for testing
                    $vmk = Get-VMHostNetworkAdapter -VMHost $vmhost -VMKernel | Where {$_.PortGroupName -eq $testPortgroup.Name} -ErrorAction SilentlyContinue
                    If ($vmk -eq $null) {
                        Write-Verbose "Creating test vmk adapter on vdswitch: $vdswitch"
                        $vmk = New-VMHostNetworkAdapter -VMHost $vmhost -VirtualSwitch $vdswitch -PortGroup $testPortgroup
                    }
                    If ($testIP -match 'dhcp') {
                        Write-Verbose "Configuring test vmk for dhcp"
                        Set-VMHostNetworkAdapter -VirtualNic $vmk -Dhcp -Confirm:$false | Out-Null
                    }
                    Else {
                        Write-Verbose "Configuring test vmk with IP $testIP, mask $testMask"
                        Set-VMHostNetworkAdapter -VirtualNic $vmk -IP $testIP -SubnetMask $testMask -Confirm:$false | Out-Null
                    }

                }
                Catch {
                    Write-Host "Error creating test portgroup/vmk : $($error[0].Exception)"
                    $message = "$($error[0].Exception)"
                }

                # Get active uplinks on test portgroup
                $testUplinks = (Get-VDUplinkTeamingPolicy -VDPortgroup $testPortgroup).ActiveUplinkPort

                # Set uplink policy on test portgroup if it doesn't match
                If ((Compare-Object $activeUplinks $testUplinks) -ne $null) {
                    Write-Verbose "Setting uplinks on test portgroup: $testPortgroup"
                    If ($standByUplinks -ne $null) {
                        Get-VDUplinkTeamingPolicy -VDPortgroup $testPortgroup | Set-VDUplinkTeamingPolicy -StandbyUplinkPort $standbyUplinks | Out-Null
                    }
                    If ($unusedUplinks -ne $null) {
                        Get-VDUplinkTeamingPolicy -VDPortgroup $testPortgroup | Set-VDUplinkTeamingPolicy -UnusedUplinkPort $unusedUplinks | Out-Null
                    }
                    Get-VDUplinkTeamingPolicy -VDPortgroup $testPortgroup | Set-VDUplinkTeamingPolicy -ActiveUplinkPort $activeUplinks | Out-Null

                    $testUplinks = (Get-VDUplinkTeamingPolicy -VDPortgroup $testPortgroup).ActiveUplinkPort
                }

                Write-Verbose "Active uplinks to test: $testUplinks"

                ForEach ($uplink in $testUplinks) {
                    # Reset variables
                    $result, $status, $message = $null

                    # Set current uplink active and others to unused
                    If ($testUplinks.Count -gt 1) {
                        Get-VDUplinkTeamingPolicy -VDPortgroup $testPortgroup | Set-VDUplinkTeamingPolicy -ActiveUplinkPort $uplink -UnusedUplinkPort ($testUplinks -notmatch $uplink) | Out-Null
                    }

                    Write-Host "Testing uplink: $uplink"

                    # Ping test IP
                    $result = @($esxcli.Network.Diag.Ping(3,$false,$true,$targetIP,$vmk,$null,$true,$false,$null,$null,$null,$null,$null))

                    If ($result.Summary -ne $null) {
                        If ($result.Summary.Recieved -eq $result.Summary.Transmitted) {
                            $status = "Passed"
                        }
                        ElseIf ($result.Summary.Recieved -gt 0) {
                            $status = "Partial"
                        }
                        Else {
                            $status = "Failed"
                        }
                        Write-Host "Packets Sent: $($result.Summary.Transmitted), Received: $($result.Summary.Recieved)"
                    }
                    Else {
                        $status = "Failed"
                        $message = 'No results from "esxcli network diag ping".'
                        Write-Host 'No results from "esxcli network diag ping".'
                    }

                    # Save results
                    $properties = [ordered]@{
                        'HostName' = $hostname
                        'VDSwitch' = $vdswitch
                        'Uplink' = $uplink
                        'VLAN' = $vlanid
                        'Status' = $status
                        'Tx' = $result.Summary.Transmitted
                        'Rx' = $result.Summary.Recieved
                        'Message' = $message
                    }
                    $results += New-Object -TypeName PSObject -Property $properties
                } # end uplink loop
            } # end portgroup loop

            # Remove test vmkernel
            If ($vmk -ne $null) {
                Write-Verbose "Removing test vmk on vdswitch: $vdswitch"
                Remove-VMHostNetworkAdapter -Nic $vmk -Confirm:$false | Out-Null
            }
            #Remove-VDPortGroup -VDPortGroup $testPortgroup -Confirm:$false | Out-Null
       } # end vdswitch loop
   } # end foreach loop
} # end process block

End {
    # Save results to CSV
    $results | Export-Csv -Path $output -NoTypeInformation

    # Write results to the console
    $results | Format-Table
}
