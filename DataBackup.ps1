<#PSScriptInfo

.VERSION 
    1.0

.GUID 
    24733d82-8178-47b2-b49a-c4c1e3eff00a

.AUTHOR 
    Justin Germain

.COMPANYNAME 
    Redacted

.COPYRIGHT 
    The MIT License (MIT)

.LICENSEURI 
    https://opensource.org/licenses/MIT

.TAGS 
    JIRA Task #####, Directory Contents, File Information

.GIT URI
    https://github.com/jgermainSM/DataBackup

.POSSIBLE ENHANCEMENTS
    Multithreading if there is a large collection of devices
    Validate elevated credentials against AD group before proceeding with script
    Log the user running the backup
    Additional logging(Failure states, existing backup overwritten)
    Progress Bar/Indicator
    Output logs to SQL database

.RELEASE NOTES
    This script backups the contents of a target folder on a remote system over SMB Admin share.    

.REQUIREMENTS 
    SMB C:\ Admin share must be enabled on target devices
    Script runner must have sufficient permissions for remote access to the target devices via SMB Admin Share
    PS 3.0 or greater
    PS ExcutionPolicy must be configured to allow the script to run
#>

###
#Initiate Variables
###

#Collect elevated credentials for the remote connections
$Script:elevatedCredentials = Get-Credential
#Define output path
$outputPath = "$env:APPDATA\RedactedBackup"
#Define backup path
$backupPath = "FooDir"
#Cleanup PSDrive for testing
Remove-PSDrive tempDrive -ErrorAction SilentlyContinue

###
#Initiate Tool Folder Structure
###

if(!(Test-Path -path "$outputPath\Backup Content")){New-Item -ItemType "Directory" -Path "$outputPath\Backup Content"}


Function importCSV{  

    #Attempt to import target computer CSV from root of script launch
    Try {
        return Import-Csv $PSScriptRoot\Computers.csv
    }

    #If file is not present, prompt user to select target computer csv
    Catch{
        #Inform User file was not present
        [System.Windows.MessageBox]::Show('Target computer csv "Computers.csv" file was not found in the folder from which the script was launched.  Please press Ok and then select the computer target csv file.','Error','Ok','Error')

        #Generate an open file dialog and filter for CSV only.  It's probably on desktop so initiate there
        Add-Type -AssemblyName System.Windows.Forms
        $explorer = New-Object System.Windows.Forms.OpenFileDialog -Property @{ InitialDirectory = [Environment]::GetFolderPath('Desktop') 
        Filter = 'CSV Files (*.csv)|*.csv'}
        
        #Initiate Dialog display
        $null = $explorer.ShowDialog()

        #Import CSV based on User Selection
        return Import-Csv $explorer.FileName
    }
}

Function EstablishConnection($checkSystem){
    #Clearing variables to ensure we don't bring any forward into the next loop in the event of an error (Optional logging vars)
    clear-variable systemState -ErrorAction SilentlyContinue
    clear-variable driveMount -ErrorAction SilentlyContinue
    clear-variable remotePath -ErrorAction SilentlyContinue

    #Ensure the system is available via ICMP before attempting to access files as it fails faster against an offline machine than SMB
    If(Test-Connection -Count 1 -ComputerName $checkSystem -Quiet){
        #This var is currently not used
        $systemState = $True
        
        #If ICMP was successful, Try to mount the SMB Admin Share (Default scope is function so adding script scope)(Piping to Null to prevent result being returned by function)
        try{
            New-PSDrive -Name tempDrive -PSProvider FileSystem -Root \\$checkSystem\C$\$backupPath -Credential $elevatedCredentials -Scope script > $null
        }
        Catch{
            #Something went wrong and we couldn't connect
            return $False
        }
        
        #This var is currently not used
        $driveMount = $True           
            
        #Ensure target folder exists on remote system
        If(Test-Path \\$checkSystem\C$\$backupPath){
            
            #This var is currently not used
            $remotePath = $True
            
            return $True           
        }
        #Folder does not exist on remote system
        Else{
            return "Folder does not exist"
        }
    }
    
    #The system was not pingable by ICMP (Connection Failed)
    Else{
    Return $False        
    }
}

Function LogConnection($currentHostname, $connectionStatus){
    
    #Gather current time in local time to log initial SMB connection and make it a script variable for logging later (-format o is a detailed timestamp and allows for easier machine sorting)
    $connectionTime = Get-Date -Format o
    
    #Create a new object to acumulate the variables from this connection attempt
    New-Object -TypeName PSCustomObject -Property @{
    Hostname = $currentHostname
    ConnectionTime = $connectionTime
    ConnectionStatus = $connectionStatus
    } | 

    #Piping the object to a select to order the results
    Select Hostname, ConnectionStatus, ConnectionTime | 
    #Appending the results to the output CSV file.  The first run will provide headers and noTypeInformation prevents the PSObjectInfo from being added to the file
    Export-Csv -Path $outputPath\ConnectionLog.csv -Append -NoTypeInformation

}

Function Backup($systemHostname){
    
    #Initally setting variable to run backup process
    $skipBackup = $false

    ###Existing File Check

    #As the intention of the user is unknown for the scope of the code verify if a backup already exists.
    if(Test-Path "$outputPath\Backup Content\$systemHostname"){
        #An existing backup is present, prompt the user for next steps
        $Popup = [System.Windows.MessageBox]::Show("A Backup for $systemHostname already exists, would you like to overwrite?",'Existing backup detected!','YesNo','Error')
        
        #User click No on Overwrite Prompt
        if($Popup -eq "No"){
            $skipBackup = $true
        }
        
        #User click Yes on Overwrite Prompt
        if($Popup -eq "Yes"){
        #Deleting existing folder (Will be replaced by main task)
        Remove-Item "$outputPath\Backup Content\$systemHostname" -Recurse -Force -Verbose
        }
    }
    ###Backup Start
    
    #This if statement skips the backup if the systen was previously backed up and the user selected "No" 
    if($skipBackup -eq $false){
    #Create a folder on the local system for the backup content with the name of the remote system being backed up
    New-Item -ItemType "Directory" -Path "$outputPath\Backup Content\$systemHostname" -Force
    
    #Start the copy off all contents of the tartget directory and all sub directories (-PassThrough allows logging of the copied content)
    $copyRecord = Copy-Item "\\$systemHostname\C$\$backupPath" -Destination "$outputPath\Backup Content\$systemHostname\" -Force -Recurse -PassThru
    
    #Massaging the content log records
    $copyRecord | 
    #Removing directories from the content log
    Where-Object{$_.Attributes -ne "Directory"} | 
    #Renaming the headers of the content log
    Select -property @{N='Name';E={$_.Basename}}, @{N='Type';E={$_.Extension}}, @{N='Size(In bytes)';E={$_.Length}} |
    #Finally exporting the content as csv (-Append isn't needed as we are exporting the entire record at once)
    Export-Csv -Path "$outputPath\Backup Content\$systemHostname\ItemLog.csv" -Append -NoTypeInformation
    
    #Closing the connection to the remote server as it is no longer required
    Remove-PSDrive tempDrive
    }
}

Function Main{

    #Call our function to import the computer.csv with our target systems.
    $targetSystems = ImportCSV

    #Iterate through the systems in the csv (-Skip 1 to avoid the header)
    foreach($currentSystem in ($targetSystems | select -Skip 1)){
    
        #Declare the hostname as a variable for simplicity
        $currentHostname = $currentSystem.Hostname

        #Pass the currently targeted system to our validation function to see if it can be connected to    
        $connectionResult = EstablishConnection($currentHostname)
    
        #Pass the hostname and result from the connection test to the connection logging module
        LogConnection $currentHostname $connectionResult

        #If the SMB drive connection was successfull, initiate the backup
        if($connectionResult -eq $true){
        Backup $currentHostname
        }    
    }
#We have iterated all devices send completion message to console
Write-Host "All devices processed - Task complete"
}

###Init Main
Main
