<#
 BIOS Sledgehammer
 Copyright (c) 2015-2018 Michael 'Tex' Hex 
 Licensed under the Apache License, Version 2.0. 

 https://github.com/texhex/BiosSledgehammer
#>

# Activate verbose output:
# .\BiosSledgehammer.ps1 -Verbose

# Wait 30 seconds at the end of the script
# .\BiosSledgehammer.ps1 -WaitAtEnd

# Activate UEFI Boot mode for the current model (for MBR2GPT.exe)
# .\BiosSledgehammer.ps1 -ActivateUEFIBoot

[CmdletBinding()]
param(
    [Parameter(Mandatory = $False)]
    [switch]$WaitAtEnd = $False,

    [Parameter(Mandatory = $False)]
    [switch]$ActivateUEFIBoot = $False
)


#Script version
$scriptversion = "4.0.7"

#This script requires PowerShell 4.0 or higher 
#requires -version 4.0

#Guard against common code errors
Set-StrictMode -version 2.0

#Require full level Administrator
#requires -runasadministrator

#Import Module with some helper functions
Import-Module $PSScriptRoot\MPSXM.psm1 -Force


#----- ACTIVATE DEBUG MODE WHEN RUNNING IN ISE -----
$DebugMode = Test-RunningInEditor
if ( $DebugMode )
{
    $VerbosePreference_BeforeStart = $VerbosePreference
    $VerbosePreference = "Continue"
    Clear-Host
}
#----DEBUG----


#log the output
Start-TranscriptTaskSequence -NewLog

#This banner was taken from http://chris.com/ascii/index.php?art=objects/tools
#region BANNER
$banner = @"

            _
    jgs   ./ |   
         /  /    BIOS Sledgehammer Version @@VERSION@@
       /'  /     Copyright (c) 2015-2018 Michael 'Tex' Hex
      /   /      
     /    \      https://github.com/texhex/BiosSledgehammer
    |      ``\   
    |        |                                ___________________
    |        |___________________...-------'''- - -  =- - =  - = ``.
   /|        |                   \-  =  = -  -= - =  - =-   =  - =|
  ( |        |                    |= -= - = - = - = - =--= = - = =|
   \|        |___________________/- = - -= =_- =_-=_- -=_=-=_=_= -|
    |        |                   ``````-------...___________________.'
    |________|   
      \    /     This is *NOT* sponsored/endorsed by HP or Intel.  
      |    |     This is *NOT* an official HP or Intel tool.
    ,-'    ``-,   
    |        |   Use at your own risk.
    ``--------'   
"@
#endregion

#Show banner
$banner = $banner -replace "@@VERSION@@", $scriptversion
write-host $banner


#Configure with temp folder to use
Set-Variable TEMP_FOLDER (Get-TempFolder) -option ReadOnly -Force
#When using a different folder, do not use a trailing backslash ("\")
#Set-Variable TEMP_FOLDER "C:\TEMP" -option ReadOnly -Force

#Configure which BCU version to use 
#Version 2.45 and upwards: BCU 4.0.21.1
Set-Variable BCU_EXE_SOURCE "$PSScriptRoot\BCU-4.0.24.1\BiosConfigUtility64.exe" -option ReadOnly -Force
#for testing if the arguments are correctly sent to BCU
#Set-Variable BCU_EXE "$PSScriptRoot\BCU-4.0.24.1\EchoArgs.exe" -option ReadOnly -Force

#For performance issues (AV software that keeps scanning EXEs from network) we copy BCU locally
#The file will be deleted when the script finishes
Set-Variable BCU_EXE "" -Force

#Configute which ISA00075 version to use
Set-Variable ISA75DT_EXE_SOURCE "$PSScriptRoot\ISA75DT-1.0.3.215\Intel-SA-00075-console.exe" -option ReadOnly -Force

#Path to password files (need to have the extension *.bin)
Set-Variable PWDFILES_PATH "$PSScriptRoot\PwdFiles" -option ReadOnly -Force

#Will store the currently used password file (copied locally)
#The file will be deleted when the script finishes
Set-Variable CurrentPasswordFile "" -Force

#Path to model files
Set-Variable MODELS_PATH "$PSScriptRoot\Models" -option ReadOnly -Force

#Path to shared files
Set-Variable SHARED_PATH "$PSScriptRoot\Shared" -option ReadOnly -Force


#Common exit codes
Set-Variable ERROR_SUCCESS_REBOOT_REQUIRED 3010 -option ReadOnly -Force
Set-Variable ERROR_RETURN 666 -option ReadOnly -Force




function Test-Environment()
{
    write-host "Verifying environment..." -NoNewline

    try
    {
        if ( -not (OperatingSystemBitness -Is64bit) ) 
        {
            throw "A 64-bit Windows is required"
        }

        if ( (Get-CurrentProcessBitness -IsWoW) )
        {
            throw  "This can not be run as a WoW (32-bit on 64-bit) process"
        }

        if ( -not (Test-FileExists $BCU_EXE_SOURCE) ) 
        {
            throw "BiosConfigUtility [$BCU_EXE_SOURCE] not found"
        }

        if ( -not (Test-DirectoryExists $PWDFILES_PATH) ) 
        {
            throw "Folder for password files [$PWDFILES_PATH] not found"
        }

        if ( -not (Test-DirectoryExists $MODELS_PATH) )
        {
            throw "Folder for model specific files [$MODELS_PATH] not found"
        }

        if ( -not (Test-DirectoryExists $SHARED_PATH) )
        {
            throw "Folder for shared files [$SHARED_PATH] not found"
        }

        if ( -not (Test-DirectoryExists $TEMP_FOLDER) )
        {
            throw "TEMP folder [$TEMP_FOLDER] not found"
        }

        $Make = (Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10).Manufacturer
        
        if ( (Test-String $Make -StartsWith "HP") -or (Test-String $Make -StartsWith "Hewlett") )
        {
            #All seems to be fine
        }
        else
        {
            throw "Unsupported manufacturer [$Make]"
        }                                                                    

        write-host "  Success"

        return $true
        
    }
    catch
    {
        write-host "  Failed!"
        throw $_
    }

}


function Test-BiosCommunication()
{  
    write-host "Verifying BIOS Configuration Utility (BCU) can communicate with BIOS." 

    write-host "  Trying to read Universally Unique Identifier (UUID)..." -NoNewline

    #Newer models use "Universally Unique Identifier (UUID)"  
    #At least the ProDesk 600 G1 uses the name "Enter UUID"  
    #Raynorpat (https://github.com/raynorpat): My 8560p here uses "Universal Unique Identifier(UUID)", not sure about other older models...
    $UUIDNames = @("Universally Unique Identifier (UUID)", "Enter UUID", "Universal Unique Identifier(UUID)")
  
    if ( (Test-BiosValueRead $UUIDNames) )
    {
        write-host "  Success"
        return $true
    }
    else
    {
        write-host "  Failed."

        #Some revision of some older models (8x0 G1 for example) might have a BIOS bug. In these cases BCU never returns UUID, 
        #although everything else works fine. We try to read "Serial Number" in this case
        write-host "  Trying to read Serial Number (S/N)..." -NoNewline
       
        $SNNames = @("Serial Number", "S/N")
       
        if ( (Test-BiosValueRead $SNNames) )
        {
            write-host "  Success"
            return $true
        }
        else
        {
            write-host "  Failed."
            throw "BCU is unable to communicate with BIOS, can't continue."
        }
    }

}

function Test-BiosValueRead()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $false)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ValueNames
    )
    $result = $false

    #Remove -Silent in order to see what this command does
    $testvalue = Get-BiosValue -Names $ValueNames -Silent
    
    if ( -not (Test-String -IsNullOrWhiteSpace $testvalue) ) 
    {
        $result = $true
    }

    return $result
}


function Get-ModelFolder()
{
    param(
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelsFolder
    )   

    $compSystem = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10    
    
    $Model = Get-PropertyValueSafe $compSystem "Model" ""
    $SKU = Get-PropertyValueSafe $compSystem "SystemSKUNumber" ""

    Write-HostSection "Locate Model Folder"
    write-Host "Searching [$ModelsFolder]"
    
    if ( Test-String -HasData $SKU )
    {
        write-Host "  for SKU [$SKU] or [$Model]..."
    }
    else
    {
        write-Host "      for [$Model]..."    
    }
    
    $result = $null

    #get all folders
    $folders = Get-ChildItem -Path $ModelsFolder -Directory -Force

    #Try is to locate a folder matching the SKU number
    if ( Test-String -HasData $SKU )
    {
        write-host "  Searching for SKU folder..."
        foreach ($folder in $folders) 
        {
            $name = $folder.Name.ToUpper()
    
            if ( $name -eq $SKU.ToUpper() )
            {
                $result = $folder.FullName
                write-host "    Matching folder: [$result]"
                break
            }
        }
        if ( $result -eq $null ) {  write-host "    No folder found" }
    }
        
    #Try is to locate a folder matching EXACTLY the model name  
    if ( $result -eq $null )
    {
        write-host "  Searching for exactly matching folder for this model..."
        foreach ($folder in $folders) 
        {
            $name = $folder.Name.ToUpper()

            if ( $name -eq $Model.ToUpper() )
            {
                $result = $folder.FullName
                write-host "    Matching folder: [$result]"
                break
            }
        }
        if ( $result -eq $null ) {  write-host "    No folder found" }
    }

    #Try a partitial model name search
    if ( $result -eq $null )
    {
        write-host "  Searching for partially matching folder..."
     
        foreach ($folder in $folders) 
        {
            $name = $folder.Name
        
            if ( Test-String $Model -Contains $name )
            {
                $result = $folder.FullName
                write-host "    Matching folder: [$result]"
                break
            }
        }
    }
    if ( $result -eq $null ) {  write-host "    No folder found" }


    if ( $result -ne $null )
    {
        Write-Host "Model folder is [$result]"
    }
    else
    {
        throw "A matching model folder was not found in [$ModelsFolder]. This model [$Model] (SKU $SKU) is not supported by BIOS Sledgehammer."
    }

    Write-HostSection -End "Model Folder"
    return $result
}


function Get-ModelSettingsFile()
{
    param(
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFolder,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$Name        
    )   

    $fileName = $null

    #First check for a direct file
    $checkFile = "$($ModelFolder)\$($Name)"
    write-host "Reading settings from [$checkFile]..."
    
    if ( Test-FileExists $checkFile ) 
    {
        #File found, use it
        $fileName = $checkFile
    }
    else
    {
        #Not found, check if a shared file exists
        $checkFile = "$($ModelFolder)\Shared-$($Name)"

        write-host "File does not exist, looking for shared file [$checkFile]"

        if ( Test-FileExists $checkFile ) 
        {            
            #Shared file exists, try to read it to get the folder name
            write-host "  Shared file found"
            $settings = Read-StringHashtable $checkFile

            if ( -not ($settings.ContainsKey("Directory")) )
            {
                throw "Shared file [$checkFile] is missing Directory setting"
            }
            else
            {
                $checkPath = Join-Path -Path $SHARED_PATH -ChildPath $settings.Directory

                if ( -not (Test-DirectoryExists $checkPath) )
                {
                    throw "Directory [$checkPath] specified in [$checkFile] does not exist"
                }                   
                else
                {
                    #Given folder exists, does the file also exist?
                    $checkFile = Join-Path -Path $checkPath -ChildPath $Name

                    if ( -not (Test-FileExists $checkFile) ) 
                    {
                        throw "Settings file [$Name] not found in shared directory [$checkPath]"
                    }
                    else
                    {
                        write-host "Using settings from [$checkFile]"
                        $FileName = $checkFile                        
                    }
                    
                }
            }

        }
        else
        {
            #Shared file does also not exist
            $fileName = $null
        }        
    }

    if ( $fileName -eq $null)
    {
        write-host "No settings file was found"
    }

    return $fileName
}


function Get-UpdateFolder()
{
    param(
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$SettingsFilePath,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$Name             
    )   

    #$folderPath=$null

    $baseFolder = Get-ContainingDirectory -Path $SettingsFilePath
    
    $folder = Join-Path -Path $baseFolder -ChildPath $Name

    if ( Test-DirectoryExists $folder )
    {
        return $folder
    }
    else
    {
        throw "Folder [$folder] does not exist"
    }

}



function ConvertTo-DescriptionFromBCUReturncode()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$Errorcode
    )
 
    $Errorcode = $Errorcode.Trim()
 
    #I should cache this. 
    $lookup =
    @{ 
        "0" = "Success"; "1" = "Not Supported"; "2" = "Unknown"; "3" = "Timeout"; "4" = "Failed"; "5" = "Invalid Parameter"; "6" = "Access Denied";
        "10" = "Valid password not provided"; "11" = "Config file not valid"; "12" = "First line in config file is not the BIOSConfig";
        "13" = "Failed to change setting"; "14" = "BCU not ready to write file."; "15" = "Command line syntax error."; "16" = "Unable to write to file or system";
        "17" = "Help is invoked"; "18" = "Setting is unchanged"; "19" = "Setting is read-only"; "20" = "Invalid setting name"; "21" = "Invalid setting value";
        "23" = "Unable to connect to HP BIOS WMI namespace"; "24" = "Unable to connect to HP WMI namespace."; "25" = "Unable to connect to PUBLIC WMI namespace";
        "30" = "Password file error"; "31" = "Password is not F10 compatible"; "32" = "Platform does not support Unicode passwords"; "33" = "No settings to apply found in Config file"; 

        "32769" = "Extended error";
    }

    if ( $lookup.ContainsKey("$ErrorCode") )
    {
        $result = $lookup[$ErrorCode]
    }
    else
    {
        $result = "Undocumented error code"
    }

    return $result
}


function ConvertTo-ResultFromBCUOutput()
{
    param(
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$BCUOutput
    )

    $props = @{"Returncode" = [int]-1; "ReturncodeText" = [string]"Unknown"; "Changestatus" = [string]"Unknown"; "Message" = [string]"Unknown" }
    $result = New-Object -TypeName PSObject -Property $props

    write-verbose "=== BCU Result ==============================="
    write-verbose $BCUOutput.Trim()
    write-verbose "=============================================="

    try
    {
        [xml]$xml = $BCUOutput

        $info_node = select-xml "//Information" $xml
        $setting_node = select-xml "//SETTING" $xml
        $error_node = select-xml "//ERROR" $xml
        $success_node = select-xml "//SUCCESS" $xml

        #For password changes, the return value needs to be pulled from the Information node.
        #If we also have a setting node, this will overwrite this anyway.
        if ( $info_node -ne $null) 
        {
            $result.Returncode = [string]$xml.BIOSCONFIG.Information.translated
        }  

        #Try to get the data from the SETTING node
        if ( $setting_node -ne $null) 
        {        
            #This should be zero to indicate everything is OK
            $result.Returncode = [string]$xml.BIOSCONFIG.SETTING.returnCode
            $result.Changestatus = [string]$xml.BIOSCONFIG.SETTING.changeStatus
            $result.Message = "OK"
        }
     
        #if there is an error node, we get the message from there
        if ( $error_node -ne $null ) 
        {
            #The error message is in the first error node
            $result.Message = [string]$error_node[0].Node.Attributes["msg"].'#text'
         
            #The error code is inside the LAST error node
            $result.Returncode = [string]$error_node[$error_node.Count - 1].Node.Attributes["real"].'#text'
        }
        else
        {
            #If no ERROR node exists, we can check for SUCCESS Nodes
            if ( $success_node -ne $null) 
            {          
                #Check if this a single node or a list of nodes
                try 
                {
                    $success_node_count = $success_node.Count
                }
                catch 
                {
                    $success_node_count = 0
                }
            
                #If we have more than one node, use the last SUCCESS node
                if ( $success_node_count -gt 0 ) 
                {
                    #the message is in the last SUCCESS node
                    $result.Message = [string]$success_node[$success_node.Count - 1].Node.Attributes["msg"].'#text'
                }
                else
                {
                    #single node
                    $result.Message = [string]$success_node.Node.Attributes["msg"].'#text'
                }
            }
        }

    }
    catch
    {
        throw "Error trying to parse BCU output: $($error[0])"
    }

    #Try to get something meaningful from the return code
    $result.ReturncodeText = ConvertTo-DescriptionFromBCUReturncode $result.Returncode

    return $result
}


function Get-BiosValue()
{
    param(
        [Parameter(Mandatory = $True, ParameterSetName = "SingleValue")]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $True, ParameterSetName = "NameArray")]
        [array]$Names,

        [Parameter(Mandatory = $False, ParameterSetName = "SingleValue")]
        [Parameter(Mandatory = $False, ParameterSetName = "NameArray")]
        [switch]$Silent = $False
    )

    $result = $null

    switch ($PsCmdlet.ParameterSetName)
    {  
        "SingleValue"
        {
            if (-not ($Silent)) { write-host "Reading BIOS setting [$Name]..." }

            try
            {
                #Try to get a single value

                #Starting with BCU 4.0.21.1, a call to /GetValue will cause BCU to write a 
                #single text file with the name of the setting to the current working directory. 
                #We change the current directory to TEMP to avoid any issues.
                $previousLocation = Get-Location         
                Set-Location $($TEMP_FOLDER) | Out-Null
         
                #$output=&$BCU_EXE -getvalue $Name | Out-String
                $output = &$BCU_EXE /GetValue:`"$Name`" | Out-String

                Set-Location $previousLocation -ErrorAction SilentlyContinue | Out-Null

         
                write-verbose "Read BIOS value: Result from BCU ============="
                write-verbose $output.Trim()
                write-verbose "=============================================="

                [xml]$xml = $output
     
                #This is the actual value
                $result = $xml.BIOSCONFIG.SETTING.VALUE.InnerText

                #This should be zero to indicate everything is OK
                $returncode = $xml.BIOSCONFIG.SETTING.returnCode

                write-verbose "Value: $result"
                write-verbose "Return code: $returncode"

                if ($returncode -ne 0) 
                {
                    if (-not ($Silent)) { write-host "    Get-BiosValue failed. Return code was $returncode" }
                    $result = $null
                }
                else
                {
                    if (-not ($Silent)) { write-host "    Setting read: [$result]" }
                }
            }
            catch
            {
                if ( -not $Silent ) 
                { 
                    write-host "    Get-BiosValue failed! Error:" 
                    write-host $error[0] 
                }
                else
                {
                    #even if we are silent, we will at least write the information with verbose
                    write-verbose "    Get-BiosValue failed! Error:" 
                    write-verbose $error[0] 
                }
                $result = $null
            }
        }

        "NameArray"
        {
            write-verbose "Reading BIOS setting using different setting names"

            $result = $null

            foreach ($Name in $Names)
            {
                Write-Verbose "   Trying using setting name [$Name]..."
        
                $value = Get-BiosValue -Name $Name -Silent:$Silent

                if ( $value -ne $null) 
                {
                    #We have a result
                    $result = $value
                    break
                }
            }
      
        }

    }
 
    return $result
}


function Set-BiosPassword()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFolder,
  
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$PwdFilesFolder,

        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [string]$CurrentPasswordFile = ""
    )

    $result = $null
    
    Write-HostSection -Start "Set BIOS Password"

    $settingsFile = Get-ModelSettingsFile -ModelFolder $ModelFolder -Name "BIOS-Password.txt"
     
    if ( $settingsFile -ne $null ) 
    {
        $settings = Read-StringHashtable $settingsFile

        if ( -not ($settings.ContainsKey("PasswordFile")) ) 
        {
            throw "Configuration file is missing [PasswordFile] setting"
        }
        
        $newPasswordFile = $settings["PasswordFile"]
        $newPasswordFile_FullPath = ""
        $newPasswordFile_Exists = $false

        #check if the file exists, given that it is not empty
        if ( $newPasswordFile -ne "")
        {
            $newPasswordFile_FullPath = "$PwdFilesFolder\$newPasswordFile"

            if ( Test-FileExists $newPasswordFile_FullPath )
            {
                $newPasswordFile_Exists = $true   
            }
            else
            {
                throw "New password file [$newPasswordFile_FullPath] does not exist"
            }
        }
        else
        {
            #if the new password is empty it automatically "exists"
            $newPasswordFile_Exists = $true
        }


        if ( $newPasswordFile_Exists ) 
        {
            write-host " Desired password file is [$newPasswordFile_FullPath]" 
         
            $noChangeRequired = $false

            #Check if there is the special case that the computer is using no password and this is also requested
            if ( $CurrentPasswordFile -eq $newPasswordFile )
            {
                $noChangeRequired = $True
            }
            else
            {
                #now we need to split the parameter to their file name
                $filenameOnly_Current = ""
                if ( $CurrentPasswordFile -ne "" )
                {
                    $filenameOnly_Current = Split-Path -Leaf $CurrentPasswordFile
                }

                $filenameOnly_New = ""
                if ( $newPasswordFile -ne "" )
                {
                    $filenameOnly_New = Split-Path -Leaf $newPasswordFile
                }
         
                #if the filenames match, no change is required
                if ( $filenameOnly_Current.ToLower() -eq $filenameOnly_New.ToLower() )
                {
                    $noChangeRequired = $True
                }
                else
                {
                    #Passwords do not match, we need to change them
                    $noChangeRequired = $False

                    write-host " Changing password using password file [$CurrentPasswordFile]..." 

                    if ( Test-String -HasData $CurrentPasswordFile )
                    {
                        #BCU expects an empty string if the password should be set to empty, so we use the parameter directly
                        $output = &$BCU_EXE /nspwdfile:`"$newPasswordFile_FullPath`" /cspwdfile:`"$CurrentPasswordFile`" | Out-String
                    }
                    else
                    {
                        #Currently using an empty password
                        $output = &$BCU_EXE /nspwdfile:`"$newPasswordFile_FullPath`" | Out-String                  
                    }

                    #Let this function figure out what this means     
                    $bcuResult = ConvertTo-ResultFromBCUOutput $output
     
                    Write-Verbose "  Message: $($bcuResult.Message)"
                    Write-Verbose "  Return code: $($bcuResult.Returncode)"
                    Write-Verbose "  Return code text: $($bcuResult.ReturncodeText)"

                    if ( $bcuResult.Returncode -eq 0 ) 
                    {
                        write-host "Password was changed"
                        $result = $newPasswordFile_FullPath
                    }
                    else
                    {
                        write-warning "   Changing BIOS password failed with message: $($bcuResult.Message)" 
                        write-warning "   BCU return code [$($bcuResult.Returncode)]: $($bcuResult.ReturncodeText)" 
                    }

                    #all done

                }
            }

            if ( $noChangeRequired )
            {
                write-host "BIOS is already set to configured password file, no change required."
            }
        } #new password file exists           
        
    }
   
    Write-HostSection -End "Set BIOS Password"
    return $result
}

	  
#Returns -1 = Error, 0 = OK, was already set, 1 = Setting changed
function Set-BiosValue()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$name,

        [Parameter(Mandatory = $false, ValueFromPipeline = $True)]  
        [string]$value = "",

        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [string]$PasswordFile = "",

        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [switch]$Silent = $False
    )

    $result = -1

    #check for replacement values
    #if ( ($value.Contains("@@COMPUTERNAME@@")) ) 
    if ( Test-String $value -Contains "@@COMPUTERNAME@@" )
    {
        $value = $value -replace "@@COMPUTERNAME@@", $env:computername
        if (-Not $Silent) { write-host " Update BIOS setting [$name] to [$value] (replaced)..." -NoNewline  }
    }
    else
    {
        #no replacement
        if (-Not $Silent) { write-host " Update BIOS setting [$name] to [$value]..." -NoNewline }
    }
 
    #If verbose output is activated, this line will make sure that the next call to write-verbose will be on a new line
    Write-Verbose " "
  

    #Reading a value is way faster then setting it, so we should try to read the value first.
    #However, Get-BIOSValue for settings that can have several option (e.g. Enable/Disable),
    #BCU returns something like "Disable, *Enable" where the * stands for the current value.
    #I habe no idea if we can rework the parsing of Get-BiosValue without risking to break something
    #Hence, right now we set each value directly.
    #$curvalue=Get-BiosValue -name $name -Silent
 
    try
    {
        #IMPORTANT! HP expects a single argument for /setvalue, but also a ",".
        #This "," causes PowerShell to put the value into the NEXT argument!
        #Therefore it must be escapced using "`,".
        if ( Test-String -IsNullOrWhiteSpace $passwordfile )
        {
          
            #No password defined
            write-verbose "   Will not use a password file" 
            $output = &$BCU_EXE /setvalue:"$name"`,"$value" | Out-String 

        }
        else
        {        
          
            write-verbose "   Using password file $passwordfile" 
            $output = &$BCU_EXE /setvalue:"$name"`,"$value" /cpwdfile:"$passwordFile" | Out-String 

        }

        #Get a parsed result
        $bcuResult = ConvertTo-ResultFromBCUOutput $output
     
        Write-Verbose "   Message: $($bcuResult.Message)"
        Write-Verbose "   Change status: $($bcuResult.Changestatus)"
        Write-Verbose "   Return code: $($bcuResult.Returncode)"
        Write-Verbose "   Return code text: $($bcuResult.ReturncodeText)"

        if ( ($bcuResult.Returncode -eq 18) -and ($bcuResult.Message = "skip") ) 
        {
            if (-Not $Silent) { write-host "  Done (was already set)" }
            $result = 0
        } 
        else 
        {        
            if ($bcuResult.Returncode -eq 0) 
            {
                if (-Not $Silent) { write-host "  Done" }
                $result = 1
            }
            else
            {
                if (-Not $Silent) 
                {
                    write-host " " #to create a new line
                    write-warning "   Update BIOS setting failed with status [$($bcuResult.Changestatus)]: $($bcuResult.Message)" 
                    write-warning "   Return code [$($bcuResult.Returncode)]: $($bcuResult.ReturncodeText)" 
                }

                $result = -1
            }
        }    
    }
    catch
    {
        #this should never happen
        write-host " " #to create a new line
        throw "Update BIOS setting fatal error: $($error[0])"
        $result = -1
    }
 
    return $result
}


# -1 = Error, 0 = OK but no changes, 1 = at least one setting was changed
function Set-BiosValuesHashtable()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        $Hastable,

        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [string]$Passwordfile = ""
    )

    $result = 0

    foreach ($entry in $Hastable.Keys) 
    {
        $name = $Entry.ToString()
        $value = $Hastable[$entry]
        $changed = Set-BiosValue -name $name -value $value -passwordfile $Passwordfile
     
        #Because the data in the hashtable are specifc for a model, we expect that each and every change works
        if ( ($changed -lt 0) ) 
        {
            write-error "Changing BIOS Setting [$name] to [$value] failed!"
            $result = -1
            break
        }
        else
        {
            #Set-BiosValue will return 0 if the setting was already set to and +1 if the setting was changed
            $result += $changed
        }
     
    }

    #just to make sure that we do not report more than expected
    if ( $result -gt 1 )
    {
        $result = 1
    }

    return $result
}


function Test-BiosPasswordFiles() 
{
    param(
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$PwdFilesFolder
    )   
  
    Set-Variable ASSET_NAME "Asset Tracking Number" -option ReadOnly -Force

    Write-HostSection -Start "Determine BIOS Password"

    $files = @()

    #Read all files that exist and sort them directly
    $pwd_files = Get-ChildItem -Path $PwdFilesFolder -File -Force -Filter "*.bin"  | Sort-Object
  
    #Add emppty password as first option
    $files += ""

    #Add files to our internal array
    ForEach ($pwdfile in $PWD_FILES) 
    {
        $files += $pwdfile.FullName 
    }

    #Start testing	 
    write-host "Testing BIOS passwords..."

    $oldAssettag = get-biosvalue -Name $ASSET_NAME
    write-host "Original Asset Tag [$oldAssettag]"

    $testvalue = Get-RandomString 14
    write-host "Asset Tag used for testing [$testvalue]"
  
    $matchingPwdFile = $null

    ForEach ($file in $files) 
    {       
        write-host "Trying password file [$file]"

        $result = Set-BiosValue -Name $ASSET_NAME -Value $testvalue -Passwordfile $file -Silent

        if ( ($result -ge 0) ) 
        {
            write-host "Password file is [$file]!"
            write-host "Restoring old Asset Tag..."
        
            $ignored = Set-BiosValue -Name $ASSET_NAME -Value $oldAssettag -Passwordfile $file -Silent

            $matchingPwdFile = $file
            break
        }
     
    }

    #Check if we were able to locate a password file
    if ( $matchingPwdFile -eq $null )
    {
        throw "Unable to find matching BIOS password file in [$PwdFilesFolder]"
    }
      
    Write-HostSection -End "Determine BIOS Password"

    return $matchingPwdFile
}


#Special version for BIOS Version data
#It replaces the first character of a BIOS Version "F" with "1" if necessary. This is needed for older models like 2570p or 6570b:
#   http://h20564.www2.hp.com/hpsc/swd/public/detail?sp4ts.oid=5212930&swItemId=ob_173031_1&swEnvOid=4060#tab-history
#Also checks if the version begins with "v" and removes it (e.g. ProDesk 600 G1)
function ConvertTo-VersionFromBIOSVersion()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [string]$Text = ""
    )  
 
    $Text = $Text.Trim() 
    $Text = $Text.ToUpper()

    if ( Test-String $Text -StartsWith "F." )
    {
        $Text = $Text.Replace("F.", "1.")
    }

    #some models report "v" before the version
    if ( Test-String $Text -StartsWith "V" )
    {
        $Text = $Text.Replace("V", "")
    }
 
    #Issue 50 (https://github.com/texhex/BiosSledgehammer/issues/50):
    #
    #Newer BIOS versions (e.g. EliteBook 830 G5) use the version string "1.00.05" that will crash 
    #if the -RespectLeadingZeros parameter is used as the resulting version would be 1.0.0.0.5
    #
    #Therefore, check if the version only contains a single "." (dot) and only use -RespectLeadingZeros in that case
    #
    if ( ($Text.Split('.').Length - 1) -eq 1 )        
    {
        [version]$curver = ConvertTo-Version -Text $Text -RespectLeadingZeros
    }
    else
    {
        #The version string contains more than one ., try to parse the version as is
        [version]$curver = ConvertTo-Version -Text $Text
    }

    return $curver
}



function Get-BIOSVersionDetails()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$RawData
    )

    #typical examples for raw data are 
    #N02 Ver. 02.07  01/11/2016
    #L83 Ver. 01.34 
    #SBF13 F.64
    #L01 v02.53  10/20/2014

    write-verbose "Trying to parse BIOS data [$RawData]"
 
    [version]$maxversion = "99.99"
    $biosdata = [PSObject]@{"Raw" = $RawData; "Family" = "Unknown"; "Version" = $maxversion; "VersionText" = $maxversion.ToString(); "Parsed" = $false; }

    $tokens = $RawData.Split(" ")
    #We expect at least three tokens: FAMILY VER. VERSION
    if ( ! ($tokens -eq $null) ) 
    {
        $versionRaw = ""

        #We expect to have at least two elements FAMILY VERSION
        if ( $tokens.Count -ge 2 )
        {       
            $family = $tokens[0].Trim()
            write-verbose "   BIOS Family: $family"

            #now we need to check if we have exactly two or more tokens
            #If exactly so, we have FAMILY VERSION
            #If more, it can be FAMILY VER VERSION or FAMILY VER VERSION DATE or FAMILY vVERSION DATE

            if ( $tokens.Count -eq 2 ) 
            {
                $versionRaw = $tokens[1].Trim()
            }
            else
            {
                #we have more than exactly two tokens. Check if the second part is "Ver."
                if ( Test-String ($tokens[1].Trim()) -StartsWith "Ver" )
                {
                    #Use third token as version
                    $versionRaw = $tokens[2].Trim()
                } 
                else 
                {
                    $versionRaw = $tokens[1].Trim()
                }
            }

            write-verbose "   BIOS Version: $versionRaw"


            #use special ConvertTo-Version version that replace the F.XX that some models report
            [version]$curver = ConvertTo-VersionFromBIOSVersion -Text $versionraw
            if ( $curver -eq $null )
            {
                write-verbose "   Converting [$versionRaw] to a VERSION object failed"
            }
            else
            {
                $biosdata.Family = $family
                $biosdata.Version = $curver
                $biosdata.VersionText = $versioNRaw
                $biosdata.Parsed = $true
            }

            #Done
        } 
    }

    write-verbose "   BIOS Data parsed: $($biosdata.Parsed)"
    return $biosdata 
}


function Get-VersionTextAndNumerical()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$VersionText,

        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [version]$VersionObject
    )

    return "$VersionText  (Numerical: $($VersionObject.ToString()))"
}


function Copy-PasswordFileToTemp()
{
    param(
        [Parameter(Mandatory = $false)]
        [string]$SourcePasswordFile
    ) 
    $result = ""
 
    #A password file variable can be empty (=empty password), no error in this case
    if ( Test-String -HasData $SourcePasswordFile )
    {
        $result = Copy-FileToTemp -SourceFilename $SourcePasswordFile
    }

    return $result
}


function Copy-FileToTemp()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceFilename
    )

    $filenameonly = Get-FileName $SourceFilename

    #This line can cause issues later on. On some system this will be a path with "~1" in it and this can cause Remove-Item do freak out. 
    #$newfullpath="$env:temp\$filenameonly"
 
    $newfullpath = "$($TEMP_FOLDER)\$filenameonly"

    Copy-Item -Path $SourceFilename -Destination $newfullpath -Force

    return $newfullpath
}





function Update-BiosSettings()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFolder,
  
        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [string]$PasswordFile = ""
    )

    $displayText = "BIOS Settings"
 
    Write-HostSection -Start $displayText
    
    $result = Update-BiosSettingsEx -ModelFolder $ModelFolder -Filename "BIOS-Settings.txt" -PasswordFile $PasswordFile -IgnoreNonExistingConfigFile 

    Write-HostSection -End $displayText

    return $result
}

function Set-UEFIBootMode()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFolder,
  
        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [string]$PasswordFile = ""
    )

    $displayText = "Activate UEFI Boot Mode"

    Write-HostSection -Start $displayText

    $result = Update-BiosSettingsEx -ModelFolder $ModelFolder -Filename "Activate-UEFIBoot.txt" -PasswordFile $PasswordFile

    Write-HostSection -End $displayText

    return $result
}


function Update-BiosSettingsEx()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFolder,
      
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$Filename,

        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [string]$PasswordFile = "",
  
        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [switch]$IgnoreNonExistingConfigFile
    )

    $result = -1

    $configFileFullPath = Get-ModelSettingsFile -ModelFolder $ModelFolder -Name $Filename

    if ( $configFileFullPath -ne $null )
    {
        $configFileExists = Test-FileExists $ConfigFileFullPath
    }
    else
    {
        $configFileExists = $false
    }

        
    #Define we can change settings or not
    $change_settings = $false

    if ( $configFileExists ) 
    {
        $change_settings = $true
    }
    else
    {
        if ( $IgnoreNonExistingConfigFile )
        {
            $result = 0               
        } 
        else
        {
            throw "Setting file [$Filename] was not found"
            $result = -1
        }
    }


    if ( $change_settings )
    {
        #Try to read the setting file
        $settings = Read-StringHashtable $ConfigFileFullPath

        if (  ($settings.Count -lt 1) ) 
        {
            Write-Warning "Setting file ($ConfigFileFullPath) is empty"
        } 
        else
        {
            #Inform which password we use
            write-host "Using password file [$PasswordFile]" 

            #Apply settings
            $changeresult = Set-BiosValuesHashtable -Hastable $settings -Passwordfile $PasswordFile

            if ( $changeresult -lt 0 ) 
            {
                #Something went wrong applying our settings
                throw "Applying BIOS Setting failed!"
            }
       
            if ( $changeresult -eq 1 )
            {
                #Since this message will appear each and every time, I'm unsure if it should remain or not
                write-host "One or more BIOS setting(s) have been changed. A restart is recommended to activated them."
            }

            $result = $changeresult
        }
    }

    return $result
}


function Update-BiosFirmware()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFolder,

        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        $BiosDetails,

        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [string]$PasswordFile = ""
    )
 
    #HPQFlash requires oledlg.dll which is by default not included in WinPE (see http://tookitaway.co.uk/tag/hpbiosupdrec/)
    #No idea if we should check for this file if we detect HPQFlash and WinPE. 

    $result = $false

    Write-HostSection "BIOS Update"
    $settingsFile = Get-ModelSettingsFile -ModelFolder $ModelFolder -Name "BIOS-Update.txt"

    if ( $settingsFile -ne $null)
    {
        #Check if the BIOS data was parsed
        if ( -not $BIOSDetails.Parsed) 
        {
            throw "BIOS data could not be parsed, unable to check if update is required"
        }

        $details = Read-StringHashtable $settingsFile

        if ( -not($details.ContainsKey("Version")) -or -not($details.ContainsKey("Command"))  ) 
        {
            throw "Settings file is missing Version or Command settings"
        } 
        else
        {       
            $versionDesiredText = $details["version"]

            #use special ConvertTo-Version version 
            [version]$versionDesired = ConvertTo-VersionFromBIOSVersion -Text $versionDesiredText

            if ( $versionDesired -eq $null ) 
            {
                throw "Unable to parse [$versionDesiredText] as a version"
            }
            else
            {
                write-host "Current BIOS Version: $(Get-VersionTextAndNumerical $BIOSDetails.VersionText $BIOSDetails.Version)"
                write-host "Desired BIOS Version: $(Get-VersionTextAndNumerical $versionDesiredText $versionDesired)"

                if ( $versionDesired -le $BIOSDetails.Version ) 
                {
                    write-host "BIOS update not required"
                    $result = $false
                }
                else
                {
                    write-host "BIOS update required!"

                    $updateFolder = Get-UpdateFolder -SettingsFilePath $settingsFile -Name "BIOS-$versionDesiredText"

                    #check if we need to pass a firmware file based on the BIOS Family
                    $firmwareFile = ""
                    $biosFamily = $BiosDetails.Family

                    write-host "BIOS family is [$biosFamily]"
                    if ( $details.ContainsKey($biosFamily) )
                    {
                        #Entry exists
                        $firmwareFile = $details[$biosFamily]
                        write-host "  Found firmware file entry for the current BIOS family: [$firmwarefile]"                
                    } 

                    $returncode = Invoke-UpdateProgram -Name "" -Settings $details -SourcePath $updateFolder -PasswordFile $PasswordFile -FirmwareFile $firmwareFile           
     
                    if ( ($returnCode -eq 0) -or ($returnCode -eq 3010) )
                    {
                        write-host "BIOS update success"
                        $result = $true
                    }
                    else
                    {
                        $result = $null

                        if ( $returnCode -eq $null )
                        {
                            throw "Running BIOS update program failed"
                        }
                        else
                        {
                            throw "BIOS update failed, update program returned code $($returnCode)"
                        }
                    }

              
                    #update done
                }
            }
        }
    }

    Write-HostSection -End "BIOS Update"
    return $result
}


function Get-TPMDetails()
{
    write-verbose "Trying to get TPM data..."
    <# 
    More about TPM Data:
    http://en.community.dell.com/techcenter/b/techcenter/archive/2015/12/09/retrieve-trusted-platform-module-tpm-version-information-using-powershell
    http://en.community.dell.com/techcenter/enterprise-client/w/wiki/11850.how-to-change-tpm-modes-1-2-2-0
    http://www.dell.com/support/article/de/de/debsdt1/SLN300906/en
    http://h20564.www2.hp.com/hpsc/doc/public/display?docId=emr_na-c05192291
  #>

    # HP:
    #   ID 1229346816 = IFX with Version 6.40 = TPM 1.2
    # Dell:
    #   ID 1314145024 = NTC with Version 1.3 = TPM 2.0
    #   ID 1464156928 = WEC with Version 5.81 = TPM 1.2
  
    [version]$maxversion = "99.99"
    $TPMData = [PSObject]@{"ManufacturerId" = "Unknown"; "VersionText" = $maxversion.ToString(); "Version" = $maxversion; "SpecVersionText" = $maxversion.ToString(); "SpecVersion" = $maxversion; "Parsed" = $false; }

    try
    {
        $tpm = Get-CimInstance Win32_Tpm -Namespace root\cimv2\Security\MicrosoftTpm

        $TPMData.ManufacturerId = [string]$tpm.ManufacturerId
   
        $TPMData.VersionText = $tpm.ManufacturerVersion
        $TPMData.Version = ConvertTo-Version $tpm.ManufacturerVersion
   
        #SpecVersion is reported as "1.2, 2, 3" which means "TPM 1.2, revision 2, errata 3"
        #I'm pretty sure we only need to first part    
        $specTokens = $tpm.SpecVersion.Split(",")
   
        $TPMData.SpecVersionText = $specTokens[0]
        $TPMData.SpecVersion = ConvertTo-Version $specTokens[0]
 
        $TPMData.Parsed = $true
    }
    catch
    {
        write-verbose "Getting TPM data error: $($error[0])"
    }

    return $TPMData 
}


function Invoke-BitLockerDecryption()
{
    write-host "Checking BitLocker status..."

    $bitLockerActive = $false

    #we better save this all with a try-catch
    try
    {
        #Because we do not know if we can access the BitLocker module, we check the status using WMI/CMI
        $encryptableVolumes = Get-CIMInstance "Win32_EncryptableVolume" -Namespace "root/CIMV2/Security/MicrosoftVolumeEncryption"
                      
        $systemdrive = $env:SystemDrive
        $systemdrive = $systemdrive.ToUpper()

        write-verbose "Testing if system drive $($systemdrive) is BitLocker encrypted"

        if ( $encryptableVolumes -ne $null ) 
        {
            foreach ($volume in $encryptableVolumes)
            {
                write-verbose "Checking volume $($volume.DeviceID)"

                #There might be drives that are BitLocker encrypted but do not have a drive letter.
                #The system drive will always have a drive letter, so we can simply rule them out.
                #This should be the fix for issue #43 - https://github.com/texhex/BiosSledgehammer/issues/43
                if ( $volume.DriveLetter -ne $null )
                {

                    if ( $volume.DriveLetter.ToUpper() -eq $systemdrive )
                    {           
                        write-verbose "Found entry for system drive"
                               
                        #The property ProtectionStatus will also be 0 if BitLocker was just suspended, so we can't use this property.
                        #We go for EncryptionMethod which will report 0 if no BitLocker encryption is used

                        #As @GregoryMachin reported, some versions of Windows do not have this property at all so need to make sure to have access to it
                        #See https://github.com/texhex/BiosSledgehammer/issues/21
                        if ( Get-Member -InputObject $volume -Name "EncryptionMethod" -Membertype Properties )
                        {
                            #Some computers reported NULL/NIL as the output, so we need to make sure it's uint32 what is returned
                            #See https://msdn.microsoft.com/en-us/library/windows/desktop/aa376434(v=vs.85).aspx
                            if ( $volume.EncryptionMethod -is [uint32] )
                            {
                                if ( $volume.EncryptionMethod -ne 0 )
                                {
                                    $bitLockerActive = $true
                                    write-host "BitLocker is active for system drive ($systemdrive)!"
                                }                        
                                else
                                {
                                    write-verbose "BitLocker is not used"
                                }
                            }
                        }
                    }

                }
            }
        }


        if ( $bitLockerActive )
        {
            write-host "BitLocker is active for the system drive, starting automatic decryption process..."

            #Check if we can auto descrypt the volume by using the BitLocker module
            $module_avail = Get-ModuleAvailable "BitLocker"

            if ( $module_avail )
            {                            
                $header = "Automatic BitLocker Decryption"
                $text = "To perform the update, BitLocker needs to be fully decrypted"
                $footer = "You have 20 seconds to press CTRL+C to prevent this."

                Write-HostFramedText -Heading $header -Text $text -Footer $footer -NoDoubleEmptyLines:$true                          
                Start-Sleep -Seconds 20

                write-host "Starting decryption (this might take some time)..."
                $ignored = Disable-BitLocker -MountPoint $systemdrive
				
                #wait three seconds to avoid that we check the status before the decryption has started
                Start-Sleep -Seconds 3 
				

                #Now wait for the decryption to complete
                Do
                {
                    $bitlocker_status = Get-BitLockerVolume -MountPoint $systemdrive

                    $percentage = $bitlocker_status.EncryptionPercentage
                    $volumestatus = $bitlocker_status.VolumeStatus

                    #We can not check for .ProtectionStatus because this turns to OFF as soon as the decyryption starts
                    #if ( $bitlocker_status.ProtectionStatus -ne "Off" )
                              
                    #During the process, the status is "DecryptionInProgress"
                    if ( $volumestatus -ne "FullyDecrypted" )
                    {
                        write-host "  Decryption in progress, $($Percentage)% remaining ($volumestatus). Waiting 15 seconds..."
                        Start-Sleep -Seconds 15
                    }
                    else
                    {
                        write-host "  Decryption finished!"
                                 
                        #Just to be sure
                        Start-Sleep -Seconds 5

                        $bitLockerActive = $false
                        break
                    }

                } while ($true)

            }
            else
            {
                write-error "Unable to decrypt the volume, BitLocker PowerShell module not found"
            }
        } 
        else
        {
            write-host "BitLocker is not in use for the system drive"
        }
    }
    catch
    {
        write-error "BitLocker Decryption error: $($error[0])"
        $bitLockerActive = $true #just to be sure
    }


    #We return TRUE if no BitLocker is in use
    if ( -not $bitLockerActive )
    {
        return $true
    }
    else
    {
        return $false
    }
}


function Update-TPMFirmware()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFolder,

        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        $TPMDetails,

        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [string]$PasswordFile = ""
    )

    Write-HostSection "TPM Update"

    $result = $false

    $updateFile = Get-ModelSettingsFile -ModelFolder $ModelFolder -Name "TPM-Update.txt"

    if ( $updatefile -ne $null ) 
    {
        if ( -not ($TPMDetails.Parsed) ) 
        {
            throw "TPM not found or unable to parse data, unable to check if update is required"
        }
    
        $settings = Read-StringHashtable $updatefile

        if ( !($settings.ContainsKey("SpecVersion")) -or !($settings.ContainsKey("FirmwareVersion")) -or !($settings.ContainsKey("Command"))  ) 
        {
            throw "Configuration file is missing SpecVersion, FirmwareVersion or Command settings"
        }
          
        #Check if a Manufacturer was given. If so, we need to check if it matches the vendor of this machine
        $manufacturerOK = $true
      
        if ( $settings.ContainsKey("Manufacturer") )
        {       
            $tpmManufacturer = $settings["Manufacturer"]

            write-host "TPM manufacturer ID of this device: $($TPMDetails.ManufacturerId)"
            write-host "TPM manufacturer ID required......: $tpmManufacturer"

            #Yes, I'm aware this are numbers, but the day they will use chars this line will save me some debugging
            if ( $tpmManufacturer.ToLower() -ne $TPMDetails.ManufacturerId.ToLower() )
            {
                write-warning "  TPM manufacturer IDs do not match, unable to update TPM"
                $manufacturerOK = $false
            }
            else
            {
                write-host "  TPM manufacturer IDs match"
            }         
        }
        else
        {
            write-host "Manufacturer not defined in configuration file, will not check TPM manufacturer ID"
        }
  
        if ( $manufacturerOK )
        {
            #Get TPM Spec and firmwarwe version from settings
            $tpmSpecDesiredText = $settings["SpecVersion"]
            $tpmSpecDesired = ConvertTo-Version $tpmSpecDesiredText

            if ( $tpmSpecDesired -eq $null ) 
            {
                throw "Unable to convert value of SpecVersion [$tpmSpecDesiredText] to a version!"
            }

            #Check TPM spec version
            $updateBecauseTPMSpec = $false
            write-host "Current TPM Spec: $(Get-VersionTextAndNumerical $TPMDetails.SpecVersionText $TPMDetails.SpecVersion)"
            write-host "Desired TPM Spec: $(Get-VersionTextAndNumerical $tpmSpecDesiredText $tpmSpecDesired)"  

            if ( $TPMDetails.SpecVersion -lt $tpmSpecDesired )
            {
                write-host "  TPM Spec is lower than desired, update required"            
                $updateBecauseTPMSpec = $true
            }
            else
            {
                write-host "  TPM Spec version matches"
            }

            #Verify firmware version
            $firmwareVersionDesiredText = $settings["FirmwareVersion"]
            $firmwareVersionDesired = ConvertTo-Version $firmwareVersionDesiredText

            if ( $firmwareVersionDesired -eq $null ) 
            {
                throw "Unable to convert value of FirmwareVersion [$firmwareVersionDesiredText] to a version!"
            }
                        
            $updateBecauseFirmware = $false
            write-host "Current TPM firmware: $(Get-VersionTextAndNumerical $TPMDetails.VersionText $TPMDetails.Version)"
            write-host "Desired TPM firmware: $(Get-VersionTextAndNumerical $firmwareVersionDesiredText $firmwareVersionDesired)"

            if ( $TPMDetails.Version -lt $firmwareVersionDesired )
            {
                write-host "  Firmware version is lower than desired, update required"            
                $updateBecauseFirmware = $true
            }
            else
            {
                write-host "  Firmware version matches or is newer"
            }

            write-host "Update required result:"
            write-host "  Update required because of TPM Spec....: $updateBecauseTPMSpec"
            write-host "  Update required because of TPM firmware: $updateBecauseFirmware"
             
            if ( -not ($updateBecauseTPMSpec -or $updateBecauseFirmware) )
            {
                write-host "TPM update not required"
                $result = $false
            }
            else
            {
                write-host "TPM update required!"

                <#
                 We need to check for an entry *exactly* for the current firmware as HP only provides updates from A.B to X.Y 
                
                 However, we have a problem with the 6.41 firmware that is included in the firmware pack for 7.61 and upwards:
                 https://github.com/texhex/BiosSledgehammer/issues/9
                 
                 There are TWO firmware files for 6.41: 
                 6.41.197 - Used for devices that come with TPM 1.2
                 6.41.198 - Used for devices that are TPM 2.0 by default and are factory-downgraded to 1.2

                 The problem is that Win32_TPM (WMI class) does NOT list the build, only MAJOR.MINOR.

                 Hence we need to perform a double try in this special case.
                #>

                $firmmwareVersionText = $TPMDetails.VersionText                
                Write-host "Searching firmware file entry for [$firmmwareVersionText]..."

                $firmwareFile_A = ""
                $firmwareFile_B = ""
                
                $firmwareEntryFound = $false

                #First check for a drirect match, e.g. if the TPM firmware is 6.40, search for 6.40==XXXXX
                if ( $settings.ContainsKey($firmmwareVersionText) )
                {
                    $firmwareFile_A = $settings[$firmmwareVersionText]
                    write-host "Firmware file found:"
                    write-host "  [$firmwareFile_A]"

                    $firmwareEntryFound = $true
                }
                else
                {
                    #If nothing was found, check if this is a special update process so we expect VERSION.A and VERSION.B
                    #We expect two entries in this case, a single entry is a failure
                    if ( ($settings.ContainsKey("$firmmwareVersionText.A")) -and ($settings.ContainsKey("$firmmwareVersionText.B")) )
                    {                                                
                        $firmwareFile_A = $settings["$firmmwareVersionText.A"]
                        $firmwareFile_B = $settings["$firmmwareVersionText.B"]

                        write-host "Two firmware files found:"
                        write-host "  [$firmwareFile_A]"
                        write-host "  [$firmwareFile_B]"

                        $firmwareEntryFound = $true
                    }
                }
                                
                if ( -not $firmwareEntryFound )
                {
                    throw "The setting file does not contain an entry for the current TPM firmware ($firmmwareVersiontext) - unable to perform update"
                }
                     
                #$sourcefolder = "$ModelFolder\TPM-$firmwareVersionDesiredText"
                $sourceFolder = Get-UpdateFolder -SettingsFilePath $updateFile -Name "TPM-$firmwareVersionDesiredText"

                #Ensure the firmware file exist
                $testExistensFirmwareFullPath = "$sourcefolder\$firmwareFile_A"                  
                if ( -not (Test-FileExists $testExistensFirmwareFullPath) )
                {
                    throw "Firmware file [$testExistensFirmwareFullPath] does not exist!"
                }
                else
                {
                    #Check if File_B exist if the variable is filled
                    if ( Test-String -HasData $firmwareFile_B )
                    {
                        $testExistensFirmwareFullPath = "$sourcefolder\$firmwareFile_B"

                        #Check if file B exists
                        if ( -not (Test-FileExists $testExistensFirmwareFullPath) )
                        {
                            throw "Firmware file [$testExistensFirmwareFullPath] does not exist!"                            
                        }
                    }
                }
                                      

                #We might need to stop here, depending on the BitLockerStatus
                $continueTPMUpgrade = $false

                #In case of update scenarios, the operator can decide to just pause BitLocker encrpytion and does not want to have it fully decrypt
                $ignoreBitLocker = $settings["IgnoreBitLocker"]
                                                  
                if ( $ignoreBitLocker -eq "Yes") 
                {
                    write-host "BitLocker status is ignored, will continue without checking BitLocker"
                    $continueTPMUpgrade = $true
                }
                else
                {
                    #Now we have everything we need, but we need to check if the SystemDrive (C:) is full decrypted. 
                    #BitLocker might not be using the TPM , but I think the TPM update simply checks if its ON or not. If it detects BitLocker, it fails.
                    $BitLockerDecrypted = Invoke-BitLockerDecryption

                    if ($BitLockerDecrypted)
                    {
                        $continueTPMUpgrade = $true                                
                    }
                    else
                    {
                        throw "BitLocker is in use, TPM update not possible"
                    }
                }
                                           
                #DEBUG DEBUG DEBUG DEBUG DEBUG DEBUG DEBUG DEBUG 
                #$continueTPMUpgrade=$true
                #DEBUG DEBUG DEBUG DEBUG DEBUG DEBUG DEBUG DEBUG 
                      
                if ($continueTPMUpgrade)
                {                
                    #Maybe we have a BIOS that requires BIOS settings to allow the TPM update, e.g. TXT and SGX for G3 Models with BIOS 1.16 or higher                                                                                                                                              
                    $displayText = "BIOS Settings for TPM Update"

                    Write-HostSection -Start $displayText
                    $biosChanges = -1
                    $biosChanges = Update-BiosSettingsEx -ModelFolder $ModelFolder -Filename "TPM-BIOS-Settings.txt" -PasswordFile $PasswordFile -IgnoreNonExistingConfigFile                                                        
                    Write-HostSection -End $displayText -NoEmptyLineAtEnd

                    #This should not be necessary since Update-BiosSettingsEx will throw an error
                    if ( $biosChanges -lt 0 )
                    {
                        throw "BIOS changes failed, can not continue"
                    }
      
                    #
                    #Real update process starts here. We might need to do this two times in case two firmwares were found                            
                    #
                    $returnCode = Invoke-UpdateProgram -Name "TPM firmware $(Get-FileName $firmwareFile_A)" -Settings $settings -SourcePath $sourcefolder -FirmwareFile $firmwareFile_A -PasswordFile $PasswordFile

                    if ( $returnCode -eq $null )
                    {
                        #In this case, no second execution will be done because something completly failed. 
                        throw "TPM update failed!"
                    }
                    else
                    {
                        #If it's not null, we have two options:

                        # (A) Only a single firmware file exist: Assume any return code is OK
                        $updateSuccess = $false

                        if ( -not (Test-String -HasData $firmwareFile_B) )
                        {
                            $updateSuccess = $true
                        }
                        else
                        {
                            # (B) Two firmware file exist: If return code is 275 (firmware image wrong), try again with the second firmware file
                            if ( $returnCode -ne 275 )
                            {
                                #Different return code than 275, most likely the command was a success
                                $updateSuccess = $true
                            }
                            else
                            {
                                #Return code was 275 - repeat with firmwareFile_B
                                write-host "TPM update returned invalid firmware file, retrying with second firmware file..."
                                        
                                $returnCode = Invoke-UpdateProgram -Name "TPM firmware $(Get-FileName $firmwareFile_B)" -Settings $settings -SourcePath $sourcefolder -FirmwareFile $firmwareFile_B -PasswordFile $PasswordFile

                                if ( $returnCode -eq $null )
                                {
                                    #Well, that didn't worked...
                                    throw "TPM update failed!"
                                }
                                else
                                {
                                    $updateSuccess = $true
                                }
                            }                                                                        
                        }

                                                                                                 
                        if ( $updateSuccess -eq $true )
                        {
                            write-host "TPM update success"
                            $result = $True
                        }
                        else
                        {
                            #This should never be used, but still...
                            throw "Running TPM update command failed!"
                        }                                
                    }                                                                   
                }                            
            }                                
        }        
    }

    Write-HostSection -End "TPM Update"
    return $result
}


function Invoke-UpdateProgram()
{
    param(
        [Parameter(Mandatory = $False)]
        [string]$Name = "",

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [hashtable]$Settings,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,
    
        [Parameter(Mandatory = $False)]
        [string]$FirmwareFile = "",

        [Parameter(Mandatory = $False)]
        [string]$PasswordFile = "",

        [Parameter(Mandatory = $False)]
        [switch]$NoOutputRedirect = $false
    )

    $result = $null
    write-verbose "Invoke-UpdateProgram() started"
    

    write-host "Checking if the computer is on AC or DC (battery) power..."    
    
    #Checking the property might fail with the message "The property 'BatteryStatus' cannot be found on this object. Verify that the property exists."    
    try
    {        
        $batteryStatus = $null
        
        #see https://msdn.microsoft.com/en-us/library/aa394074(v=vs.85).aspx
        $batteryStatus = (Get-CimInstance Win32_Battery -ErrorAction Stop).BatteryStatus
        # "-ErrorAction Stop" is required to turn any error into a catchable error
    }
    catch
    {
        write-host "Querying CIM for Win32_Battery.BatteryStatus failed ($($error[0])), assuming this computer has no battery."
    }

    $batteryOK = $false    
    if ($batteryStatus -eq $null)
    {
        #No battery found, ignoring state 
        $batteryOK = $true
    }
    else
    {
        #On Battery (1), Critical (5), Charging and Critical (9)
        if ( ($batteryStatus -eq 1) -or ($batteryStatus -eq 5) -or ($batteryStatus -eq 9) )
        {
            throw "This device is running on battery or the battery is at a critically low level. The update will not be started to prevent possible firmware corruption."
        }
        else
        {
            $batteryOK = $true
        }
    }

    
    if ( $batteryOK ) 
    {
        write-host "  Battery status is OK or no battery present."

        if ( Test-String -HasData $Name)
        {
            write-host "::: Preparing launch of update executable - $name :::"
        }
        else
        {
            write-host "::: Preparing launch of update executable :::"
        }

        $localFolder = $null
        try
        {
            $localFolder = Copy-FolderForExec -SourceFolder $SourcePath -DeleteFilter "*.log"
        }
        catch
        {
            write-host "Preparing local folder failed: $($error[0])"
        }

        if ( $localfolder -ne $null )
        {              
            #Some HP tools require full paths for the firmware file or they will not work, especially TPMConfig64.exe
            #Therefore append the local path to the firmware if one is set
            $localFirmwareFile = $FirmwareFile
            if ( Test-String $localFirmwareFile -HasData)
            {
                $localFirmwareFile = Join-Path -Path $localFolder -ChildPath $localFirmwareFile
            }

            #Get the parameters together.
            #The trick with the parameters array is courtesy of SAM: http://edgylogic.com/blog/powershell-and-external-commands-done-right/
            $params = Get-ArgumentsFromHastable -Hashtable $Settings -PasswordFile $PasswordFile -FirmwareFile $localFirmwareFile

            #Get the exe file
            $exeFileName = $Settings["command"]        
            $exeFileLocalPath = "$localFolder\$exeFileName"               

            $result = Invoke-ExeAndWaitForExit -ExeName $exeFileLocalPath -Parameter $params -NoOutputRedirect:$NoOutputRedirect
               
            #always try to grab the log file
            $ignored = Write-HostFirstLogFound -Folder $localFolder
        }

        write-host "::: Launching update executable finished :::"
    }
    
    write-verbose "Invoke-UpdateProgram() ended"
    return $result
}

function Copy-FolderForExec()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceFolder,

        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [string]$DeleteFilter = ""
    )

    $result = $null  

    if ( -not (Test-DirectoryExists $SourceFolder) ) 
    {
        throw "Folder [$SourceFolder] not found!"
    }
    else
    {
        #When using $env:temp, we might get a path with "~" in it
        #Remove-Item does not like these path, no idea why...
        $dest = Join-Path -Path $($TEMP_FOLDER) -ChildPath (Split-Path $SourceFolder -Leaf)

        #If it exists, kill it
        if ( (Test-DirectoryExists $dest) )
        {
            try
            {
                Remove-Item $dest -Force -Recurse
            }
            catch
            {
                throw New-Exception -InvalidOperation "Unable to clear folder [$dest]: $($error[0])"
            }
        }

        #Make sure the paths end with \
        $source = Join-Path -Path $SourceFolder -ChildPath "\"  
        $dest = Join-Path -Path $dest -ChildPath "\"

        try
        {
            write-host "Copy from [$source] "
            write-host "       to [$dest] ..."
            Copy-Item -Path $source -Destination $dest -Force -Recurse
        }
        catch
        {
            throw New-Exception -InvalidOperation "Unable to copy from [$source] to [$dest]"
        }

        write-verbose "Copy done"

        #now check if we should delete something after copying it
        if ( $DeleteFilter -ne "" )
        {
            Write-Host "Trying to delete [$DeleteFilter] in target folder"
            try
            {
                $files = Get-ChildItem $dest -File -Include $deleteFilter -Recurse -Force 
                foreach ($file in $files)
                {
                    write-host "  Deleting $($file.Fullname)"
                    Remove-FileExact -Filename $file.Fullname
                }
                     
            }
            catch
            {
                throw New-Exception -InvalidOperation "Error while deleting from [$dest]: $($error[0])"
            }
        }

        #We return the destination path without the \
        return $dest.TrimEnd("\")
    }
}


function Get-ArgumentsFromHastable()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [hashtable]$Hashtable,

        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [string]$PasswordFile = "",

        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [string]$FirmwareFile = ""
    )
 
    $params = @()

    #20 parameters max should be enough
    For ($i = 1; $i -lt 21; $i++) 
    {
        if ( ($Hashtable.ContainsKey("Arg$i")) )
        {
            $params += $Hashtable["Arg$i"]
        }
        else
        {
            break
        }
    }

    #now check for replacement strings
    #We need to use a for loop since a foreach will not change the array
    for ($i = 0; $i -lt $params.length; $i++) 
    {
        if ( Test-String $params[$i] -Contains "@@PASSWORD_FILE@@" )
        {
            if ( $PasswordFile -eq "" ) 
            {
                #if no password is set, delete this paramter
                $params[$i] = ""
            }
            else
            {
                $params[$i] = $params[$i] -replace "@@PASSWORD_FILE@@", $PasswordFile    
            }
        }
       
        if ( Test-String $params[$i] -Contains "@@FIRMWARE_FILE@@" )
        {
            if ( $FirmwareFile -eq "" ) 
            {
                #if no firmware is set, delete this paramter
                $params[$i] = ""
            }
            else
            {
                $params[$i] = $params[$i] -replace "@@FIRMWARE_FILE@@", $FirmwareFile    
            }
        }

    }

    #finally copy the arguments together and leave any empty elements out
    $paramsFinal = @() 
    foreach ($param in $params) 
    {
        if ( -not (Test-String -IsNullOrWhiteSpace $param) )
        {
            $paramsFinal += $param
        }
    }
    
    return $paramsFinal  
}

function Invoke-ExeAndWaitForExit()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$ExeName,

        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [array]$Parameter = @(),

        [Parameter(Mandatory = $False)]
        [switch]$NoOutputRedirect = $false
    )

    $result = -1
  
    write-host "Starting: "
    write-host "  $ExeName"
    write-host "  $Parameter"
 
    try
    {
        #Version 1
        #We can not use this command because this will not return the exit code. 
        #Also, most HP update tools do not return anything to stdout at all.
        #$output=&$ExeName $Parameter

        #Version 2, gets exit code but no standard output
        #$runResult=Start-Process $ExeName -Wait -PassThru -ArgumentList $Parameter
        #$result=$runResult.ExitCode         

        #Version 3, hopefully the last...
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $ExeName
        $startInfo.Arguments = $Parameter
    
        $startInfo.UseShellExecute = $false #else redirected streams do not work

        if ( $NoOutputRedirect )
        {
            Write-Verbose "StdOut and StdError redirection disabled"
        }
        else
        {
            $startInfo.RedirectStandardError = $true
            $startInfo.RedirectStandardOutput = $true
        }
        
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $startInfo
        $proc.Start() | Out-Null

        #LAUNCH HERE
        $proc.WaitForExit()
    
        #Get result code
        $result = $proc.ExitCode
    
        $stdOutput = ""
        $stdErr = ""

        if ( -not $NoOutputRedirect )
        {
            $stdOutput = $proc.StandardOutput.ReadToEnd()
            $stdErr = $proc.StandardError.ReadToEnd()
        }

        write-host "  Done, return code is $result"

        $stdOutput = Get-TrimmedString $stdOutput
        $stdErr = Get-TrimmedString $stdErr
    
        write-host "--- Output ---"
        if ( Test-String -HasData $stdOutput )
        {        
            write-host $stdOutput        
        }
    
        if ( Test-String -HasData $stdErr )
        {                
            write-host "--- Error(s) ---"
            write-host $stdErr        
        }
        write-host "--------------"

        #now check if the EXE is still running in the background
        #We need to remove the extension because get-process does not list .EXE
        $execheck = [io.path]::GetFileNameWithoutExtension($ExeName)
    
        write-host "  Waiting 10 seconds before checking if the process is still running..."
        Start-Sleep -Seconds 10

        Do
        {
            $check = Get-Process "$execheck*" -ErrorAction SilentlyContinue
            if ( $check )
            {
                write-host "   [$execheck] is still runing, waiting 10 seconds..."
                Start-Sleep -Seconds 10
            }
            else
            {
                write-host "   [$execheck] is no longer running, waiting 5 seconds to allow cleanup..."
                Start-Sleep -Seconds 5
                break
            }                                                                                
        } while ($true)
     
     
        write-host "  Start of [$ExeName] done"
    }
    catch
    {
        $result = $null
        throw "Starting failed! Error: $($error[0])"
    }

    return $result               
}

function Write-HostFirstLogFound()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$Folder,

        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [string]$Filter = "*.log"
    )

    write-host "Checking for first file matching [$filter] in [$folder]..."

    $logfiles = Get-ChildItem -Path $Folder -File -Include $filter -Recurse -Force 

    if ( $logfiles -eq $null )
    {
        write-host "  No file found!"
    }
    else
    {
        $filename = $logFiles[0].FullName   
   
        $content = Get-Content $filename -Raw

        if ( Test-String $content -IsNullOrWhiteSpace )
        {
            write-host "  File $filename is empty!"
        } 
        else
        {
            Write-HostOutputFromProgram -Name $filename -Content $content    
        }
   
    }

}


function Update-MEFirmware()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $False)]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFolder
    )

    Write-HostSection "Management Engine (ME) Update"
    $result = $false

    $settingsFile = Get-ModelSettingsFile -ModelFolder $ModelFolder -Name "ME-Update.txt"

    if ( $settingsFile -ne $null )
    {    
        write-host "Starting SA-00075 discovery tool to get ME data..."
  
        #We use the XML output method, so the tool will generate a file called [DEVICENAME].xml.    
        $xmlFilename = "$TEMP_FOLDER\$($env:computername).xml"
 
        #If a file by the name already exists, delete it
        $ignored = Remove-Item -Path $xmlFilename -Force -ErrorAction SilentlyContinue
    
        try
        {
            $runToolResult = &"$ISA75DT_EXE_SOURCE" --delay 0 --writefile --filepath $TEMP_FOLDER | out-string
        }
        catch
        {
            throw "Launching [$ISA75DT_EXE_SOURCE] failed; error: $($error[0])"
        }
    
        #Output console output to make sure we have something in the log even if the XML parsing fails
        Write-HostOutputFromProgram -Name "Discovery Tool Output" -Content $runToolResult

        write-host "Processing XML result [$xmlFilename]..."        

        if ( -not (Test-FileExists $xmlFilename) ) 
        {
            throw "SA-00075 discovery tool XML output file not found"
        }
        else
        {
            $MEData = @{"VersionText" = "0.0.0"; "VersionParsed" = $false; "Provisioned" = "Unknown"; "DriverInstalled" = $false }

            try 
            {
                $xmlContent = Get-Content $xmlFilename -Raw
                [xml]$xml = $xmlContent

                $MEData.VersionText = $xml.System.ME_Firmware_Information.ME_Version

                #In some cases, the Intel tool will report "Unknown" for the version. 
                #If this happens, no ME update is possible
                if ($MEData.VersionText.ToUpper() -ne "UNKNOWN")
                {
                    $MEData.Version = ConvertTo-Version -Text $MEData.VersionText
                    $MEData.VersionParsed = $true
                }
                
                #IS75DT 1.0.3 does no longer contain the entry SKU in the XML. Still in the normal output though...
                $MEData.Provisioned = $xml.System.ME_Firmware_Information.ME_Provisioning_State

                if ( $xml.System.ME_Firmware_Information.ME_Driver_Installed -eq "True" )
                {
                    $MEData.DriverInstalled = $true
                }    
                             
                write-host "XML processing finished"
            }
            catch
            {
                throw "Unable to parse SA-00075 discovery XML file; error: $($error[0])"
            }
                 
                        
            if ( -not $MEData.VersionParsed )
            {
                throw "The SA-00075 detection tool was unable to determine the installed ME firmware version, no update possible"
            }
            else
            {
                $settings = Read-StringHashtable $settingsFile
                    
                $versionDesiredText = $settings["version"]                   
                [version]$versionDesired = ConvertTo-Version -Text $versionDesiredText

                if ( $versionDesired -eq $null ) 
                {
                    throw "Unable to parse configured version [$versionDesiredText] as a version"
                }
                else
                {
                    write-host "ME Driver is installed.....: $($MEData.DriverInstalled)"
                    write-host "Current ME firmware version: $($MEData.Version)"
                    write-host "Desired ME firmware version: $($versionDesired)"
                    
                    if ( $versionDesired -le $MEData.Version ) 
                    {
                        write-host "  ME firmware update not required"
                        $result = $false
                    }
                    else
                    {
                        write-host "  ME update required!"
                            
                        <#
                         All ME firmware downloads from HP advise that the driver needs to be installed before:                            
                         "Intel Management Engine Components Driver must be installed before this package is installed."

                         The Intel detection tool has the element "ME_Driver_Installed" which we also read into $MEData.DriverInstalled
                         True/False value if the MEI driver is present on the computer"
                            
                         Therefore we will only execute the update if a driver was detected.
                        #>

                        if ( -not $MEData.DriverInstalled )
                        {
                            throw "Unable to start ME firmware update, Management Engine Interface (MEI) driver not detected!"
                        }
                        else
                        {
                            write-host "The ME update will take some time, please be patient."
                                
                            $updateFolder = Get-UpdateFolder -SettingsFilePath $settingsFile -Name "ME-$versionDesiredText"

                            $returnCode = Invoke-UpdateProgram -Name "" -Settings $settings -SourcePath $updatefolder -FirmwareFile "" -PasswordFile "" -NoOutputRedirect
                                                        
                            if ( ($returnCode -eq 0) -or ($returnCode -eq 3010) )
                            {
                                write-host "ME update success"
                                $result = $true
                            }
                            else
                            {
                                $result = $null

                                if ( $returnCode -eq $null )
                                {
                                    throw "ME update failed"
                                }
                                else
                                {
                                    throw "ME update failed, update program returned code $($returnCode)"
                                }
                            }

                            #All done
                        }
                    }
                }    
            }                            
                                                                        
        }        
    }

 
    Write-HostSection -End "ME Update"
    
    return $result
}


function Write-HostSection()
{
    param(
        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [string]$Start = "",

        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [string]$End = "",

        [Parameter(Mandatory = $False, ValueFromPipeline = $False)]
        [switch]$NoEmptyLineAtEnd
    )

    $charlength = 65
    $output = ""
 
    if ( Test-String -HasData $Start )
    {
        $output = "***** $Start *****"
        $len = $charlength - ($output.Length)
    
        if ( $len -gt 0 ) 
        {
            $output += '*' * $len
        }
    }
    else
    {
        if ( Test-String -HasData $End )
        {
            write-host "Section -$($End)- finished"
        }
        
        $output = '*' * $charlength    
    }

    write-host $output

 
    #Add a single empty line if this is an END section
    if ( Test-String -HasData $End )
    {
        #Only write the empty line if NoEmptyLine is NOT set (=False)
        if ( $NoEmptyLineAtEnd -eq $False )
        {
            write-host "   "
        }
    }

}


function Get-StringWithBorder()
{
    param(
        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [string]$Text = ""
    )

    $linewidth = 70 
    $char = "#"

    if ( $Text -ne "" )
    {
        $startOfLine = " $char$char "
        $endOfLine = "  $char$char"

        $line = "$startOfLine $Text"
   
        $len = $linewidth - ($line.Length) - ($startOfLine.Length + 1)   
        $line += " " * $len 
   
        $line += $endOfLine
    }
    else
    {
        $line = " $($char * ($linewidth-2))"
    }

    return $line
}


function Write-HostFramedText()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$Heading,

        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        $Text,

        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$Footer,
  
        [Parameter(Mandatory = $False, ValueFromPipeline = $True)]
        [switch]$NoDoubleEmptyLines = $false

    )

    write-host " "
    if (!$NoDoubleEmptyLines) { write-host " " }
    write-host (Get-StringWithBorder)
    if (!$NoDoubleEmptyLines) { write-host (Get-StringWithBorder -Text " ") }
    write-host (Get-StringWithBorder -Text $Heading.ToUpper())
    write-host (Get-StringWithBorder -Text " ")
    if (!$NoDoubleEmptyLines) { write-host (Get-StringWithBorder -Text " ") }
 
    if ( ($Text -is [system.array]) )
    {
        foreach ($item in $text)
        {
            write-host (Get-StringWithBorder -Text "$($item.ToString())")
        }
        write-host (Get-StringWithBorder -Text " ")
    }
    else
    {
        if ( $Text -ne "" )
        {
            write-host (Get-StringWithBorder -Text "$($Text.ToString())")
            write-host (Get-StringWithBorder -Text " ")
        }
    }

    if (!$NoDoubleEmptyLines) { write-host (Get-StringWithBorder -Text " ") }
    write-host (Get-StringWithBorder -Text "$Footer")
    if (!$NoDoubleEmptyLines) { write-host (Get-StringWithBorder -Text " ") }
    write-host (Get-StringWithBorder)
    write-host " "
    if (!$NoDoubleEmptyLines) { write-host " " }
}


function Write-HostPleaseRestart()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason
    )

    Write-HostFramedText -Heading "Restart required" -Text $Reason -Footer "Please restart the computer as soon as possible."
}


function Write-HostOutputFromProgram()
{
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $True, ValueFromPipeline = $True)]
        [string]$Content
    )

    if ( Test-String -IsNullOrWhiteSpace $content )
    {
        $Content = " (No content) "
    }

    Write-HostSection "::BEGIN:: $Name"   
    Write-Host $Content
    Write-HostSection "::END:: $Name"
}


##########################################################################
##########################################################################
##########################################################################

if ( -not $DebugMode ) 
{
    $header = "This script might alter your firmware and/or BIOS settings"
    $text = ""
    $footer = "You have 15 seconds to press CTRL+C to stop it."

    Write-HostFramedText -Heading $header -Text $text -Footer $footer -NoDoubleEmptyLines:$true

    Start-Sleep 15
}

 

#set returncode to error by default
$returncode = $ERROR_RETURN

try 
{
    #verify that our environment is ready
    $ignored = Test-Environment

    #For performance reasons, copy the BCU to TEMP
    $BCU_EXE = Copy-FileToTemp $BCU_EXE_SOURCE

    #Test BCU can communicate with BIOS
    $ignored = Test-BiosCommunication
  
    #We need to do the following in the correct order
    #
    #(1) BIOS Update - Because a possible TPM update requires an updated BIOS     
    #(2) ME Update - Because some BIOS version recommand an ME firmware update, e.g. for the ProDesk 600 G2 - https://ftp.hp.com/pub/softpaq/sp78001-78500/sp78294.html    
    #(3a) TPM BIOS Changes - Modern systems do not allow an TPM Update in case SGX or TXT is activated    
    #(3b) TPM Update - Because some settings might require a newer TPM firmware    
    #(4) BIOS Password change - Because some BIOS settings (TPM Activation Policy for example) will not work until a password is set    
    #(5) BIOS Settings

    write-host "Collecting system information..."

    $compSystem = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10
    
    $Model = Get-PropertyValueSafe $compSystem "Model" ""
    $SKU = Get-PropertyValueSafe $compSystem "SystemSKUNumber" ""
    $computername = $env:computername

    write-host " "
    write-host "  Name.........: $computername"
    write-host "  Model........: $Model"
    write-host "  SKU..........: $SKU"
   
    ########################################
    #Retrieve and parse BIOS version 

    #We could use a direct call to BCU, but this does not work for old models
    #because it includes the data like this: "L01 v02.53  10/20/2014".
    #This breaks the XML parsing from Get-BiosValue because BCU does not escape the slash   
    #So we get the data directly from Windows 
    $BIOSRaw = (Get-CimInstance Win32_Bios).SMBIOSBIOSVersion
  
    #Examples:
    #L01 v02.53  10/20/2014
    #68ISB Ver. F.53
    #$BIOSRaw="L01 v02.53  10/20/2014"
    #$BIOSRaw="B0rken"

    #replace $NULL in case we were unable to retireve the data
    if ( $BIOSRaw -eq $null ) 
    { 
        $BIOSRaw = "Failed" 
    }
    $BIOSDetails = Get-BIOSVersionDetails $BIOSRaw   

    write-host "  BIOS (Raw)...: $BIOSRaw"

    if ( !($BIOSDetails.Parsed) ) 
    {
        write-warning "BIOS Data could not be parsed!"
    }
    else
    {
        write-host "  BIOS Family..: $($BIOSDetails.Family)"
        write-host "  BIOS Version.: $(Get-VersionTextAndNumerical $BIOSDetails.VersionText $BIOSDetails.Version)"
    }


    ########################################
    #Retrieve and parse TPM data

    $TPMDetails = Get-TPMDetails
    if ( !($TPMDetails.Parsed) ) 
    {
        write-host "  No TPM found or data could not be parsed."
    } 
    else
    {
        write-host "  TPM Vendor...: $($TPMDetails.ManufacturerId)"
        write-host "  TPM Firmware.: $(Get-VersionTextAndNumerical $TPMDetails.VersionText $TPMDetails.Version)"
        write-host "  TPM Spec.....: $(Get-VersionTextAndNumerical $TPMDetails.SpecVersionText $TPMDetails.SpecVersion)"
    }
    write-host " "


    #Locate Model folder
    $modelfolder = Get-ModelFolder -ModelsFolder $MODELS_PATH
        
    #Now search for the password
    $foundPwdFile = Test-BiosPasswordFiles -PwdFilesFolder $PWDFILES_PATH
      
    #Copy the password file locally 
    #IMPORTANT: If we later on change the password this file in TEMP will be deleted!
    #           Never set $CurrentPasswordFile to a file on the source!
    $CurrentPasswordFile = Copy-PasswordFileToTemp -SourcePasswordFile $foundPwdFile
                
    #Now we have everything ready to make changes to this system
    
    #If ActivateUEFIBoot is set, we only perform this change and nothing else
    if ( $ActivateUEFIBoot )
    {
        ########################
        #Switch UEFI Boot mode

        $uefiModeSwitched = Set-UEFIBootMode -ModelFolder $modelfolder -PasswordFile $CurrentPasswordFile

        $returncode = 0
    }
    else
    {
        ########################
        #Normal process 

        $biosUpdated = $false
        $biosUpdated = Update-BiosFirmware -Modelfolder $modelfolder -BIOSDetails $BIOSDetails -PasswordFile $CurrentPasswordFile

        if ( $biosUpdated ) 
        {
            #A BIOS update was done. Stop and continue later on
            $ignored = Write-HostPleaseRestart -Reason "A BIOS update was performed."                       
            $returncode = $ERROR_SUCCESS_REBOOT_REQUIRED
        }
        else 
        {
            #ME update/check                    
            $mefwUpdated = $false                     
            $mefwUpdated = Update-MEFirmware -Modelfolder $modelfolder

            if ( $mefwUpdated )
            {
                $ignored = Write-HostPleaseRestart -Reason "A ME firmware update was performed."              
                $returncode = $ERROR_SUCCESS_REBOOT_REQUIRED
            }
            else
            {
                #TPM Update
                $tpmUpdated = $false
                $tpmUpdated = Update-TPMFirmware -Modelfolder $modelfolder -TPMDetails $TPMDetails -PasswordFile $CurrentPasswordFile

                if ( $tpmUpdated )
                {
                    $ignored = Write-HostPleaseRestart -Reason "A TPM update was performed."              
                    $returncode = $ERROR_SUCCESS_REBOOT_REQUIRED
                }
                else
                {                     
                    #BIOS Password update
                    $updatedPasswordFile = Set-BiosPassword -ModelFolder $modelFolder -PwdFilesFolder $PWDFILES_PATH -CurrentPasswordFile $CurrentPasswordFile

                    if ( $updatedPasswordFile -ne $null )
                    {
                        #File has changed - remove old password file
                        $ignored = Remove-FileExact -Filename $CurrentPasswordFile
                        $CurrentPasswordFile = Copy-PasswordFileToTemp -SourcePasswordFile $updatedPasswordFile
                    }

                    #Apply BIOS Settings
                    $settingsApplied = Update-BiosSettings -ModelFolder $modelfolder -PasswordFile $CurrentPasswordFile

                    if ( ($settingsApplied -lt 0) )
                    {
                        write-warning "Applying BIOS settings completed with errors"
                    }

                    $returncode = 0

                    <#
                        Here we could normaly set the REBOOT_REQUIRED variable if BCU reports changes, but BCU 
                        does also report changes if a string value (e.g. Ownership Tag) is set to the *SAME*
                        value as before. 
                 
                        if ( $settingsApplied -ge 1 )
                        {
                          $ignored=Write-HostPleaseRestart -Reason "BIOS settings have been changed."   
                          $returncode=$ERROR_SUCCESS_REBOOT_REQUIRED
                        }
                        else
                        {
                          #no changes for BIOS setting
                          $returncode=0
                        }
                    #>                                    

                }
                
            }
            
        }
             
    }
        

    #MAIN PROCESS
    
    

}
catch
{
    write-error "$($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)`n$($_.ScriptStackTrace)" -Category OperationStopped
    #Not used right now: `n$($_.Exception.StackTrace)

    $returncode = $ERROR_RETURN
}


#Clean up
$ignored = Remove-FileExact -Filename $CurrentPasswordFile
$ignored = Remove-FileExact -Filename $BCU_EXE

write-host "BIOS Sledgehammer finished, return code $returncode."
write-host "Thank you, please come again!"

if ( $DebugMode ) 
{
    #set it back to old value
    $VerbosePreference = $VerbosePreference_BeforeStart
}
else
{
    if ( $WaitAtEnd )
    {
        write-host "Waiting 30 seconds..."
        Start-Sleep -Seconds 30
    }
}

# Stop logging
Stop-TranscriptIfSupported


Exit-Context $returncode

#ENDE 