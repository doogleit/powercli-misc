<#
.SYNOPSIS
    Gets the virtual MAC addresses assigned to each physical NIC on an ESXi host.
.DESCRIPTION
    Connects to one or more hosts using SCP and downloads the esx.conf file.  Extracts
    the virtual MAC address assigned to each physical NIC and appends them to the output
    file.  On completion checks the output file for duplicates.
.NOTES
    This script was to identify duplicate virtual MAC addresses introduced by a bug in
    ESXi 6.0 U2.  This was resolved in patch ESXi600-201608401-BG.
    From https://kb.vmware.com/s/article/2145664:
    "ESXi generates shadow NIC virtual MAC address that are duplicated across multiple ESXi
    hosts in the environment. The issue impacts the HealthCheck functionality."

    As far as I know (at the time of writing this) these virtual MAC addresses were not
    exposed by any other means and could only be found in the esx.conf file.
.LINK
    https://kb.vmware.com/s/article/2145664
#>
﻿$outputFile = ".\VirtualMacs.csv"
$duplicateFile = ".\DuplicateMacs.txt"
$pscpPath = "C:\Program Files (x86)\PuTTY\pscp.exe"
$hostPwd = "" # host root password for SCP

# Put headings in output file
"Hostname, VirtualMac" | Out-File $outputFile -Encoding ascii

# Get esx.conf file from each host and save virtual macs to output file
Get-VMHost | % {
    $virtualMacs = $null
    $vmhost = $_
    $hostname = $vmhost.Name
    $sshService = Get-VMHostService -VMHost $vmhost | where{$_.Key -eq "TSM-SSH"}

    Start-VMHostService -HostService $sshService -Confirm:$false | Out-Null

    Write-Host "Getting esx.conf for host: $hostname"
    cmd /c "echo y | `"$pscpPath`" -pw $hostPwd root@$($hostname):/etc/vmware/esx.conf .\esxconf\$hostname-esx.conf"

    Stop-VMHostService -HostService $sshService -Confirm:$false | Out-Null

    $virtualMacs = Get-Content ".\esxconf\$hostname-esx.conf" | where { $_ -match "virtualMac"}
    ForEach ($line in $virtualMacs) {
        # A line from esx.conf looks like this: /net/pnic/child[0004]/virtualMac = "00:50:56:55:06:49"
        # Split the line at the '=' sign, get the last element and strip off the quotes
        $virtualMac = ($line.Split("=")[-1]).Replace('"','')
        Write-Host "$hostname,$virtualMac"
        "$hostname,$virtualMac" | Out-File $outputFile -Append -Encoding ascii
    }
}

# Get duplicates
$allMacs = Import-Csv $outputFile
$allMacs | Group-Object -Property VirtualMac | Where {$_.Count -ge 2} | Select Name, Group | fl | Out-File $duplicateFile
