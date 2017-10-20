# get the server name
[string]$serverName = $Server = Read-Host -Prompt 'Input the deployment SSIS server name'

if ($serverName -eq "") {
    Write-Host "No SSIS server name was specified, exiting process..."
    break
}

# load assemblies required for SSIS deployment
[Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Management.IntegrationServices")>$null
$ISNamespace = "Microsoft.SqlServer.Management.IntegrationServices"
$sqlConnection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$serverName;Initial Catalog=master;Integrated Security=SSPI;"
$integrationServices = New-Object "$ISNamespace.IntegrationServices" $sqlConnection

Write-Host "Deployment to [$serverName] started."

# if SSIS catalog on server does not exist, bail
$catalog = $integrationServices.Catalogs["SSISDB"]

if (!$catalog) {
    Write-Host " "
    Write-Host "SSIS Catalog does not exist, exiting process..."
    break
}

# get the path of the script to roll through sub folders
$scriptPath = "$($pwd.Path)"
$folders = @(Get-ChildItem -Path $scriptPath | Where-Object{($_.PSIsContainer)})
$folder = $folders[0]

#
foreach ($folder in $folders) {

    #
    $catalogFolder = $catalog.Folders[$folder]

    Write-Host " "
    Write-Host "Deploying $folder objects:"

    # if the folder does not exist then create it
    if (!$catalogFolder) {
    
        Try {
            Write-Host "  Creating [$folder] folder"
            $catalogFolder = New-Object "$ISNamespace.CatalogFolder" ($catalog,$folder,$folder)            
            $catalogFolder.Create()
        } Catch {
            Write-Warning "Errors raised during deployment attempt on folder [$folder]:`n$_"
            Write-Warning "In this script context, this is usually due to security constraints."
            break
        }
 
    }
    else {
        Write-Host "  Folder [$folder] already exists"
    }
    
    # pull all the ispacs into an array
    $files = @(Get-ChildItem -Path "$scriptPath\$folder" -Name '*.ispac')
    $file = $files[0]

    # for each ispac we find, deploy it, configure it, build environment, and build agent job
    foreach ($file in $files) {

        # drop the extension from the deployment package
        $projectName = $file.replace(".ispac","")    
    
        # deploy ispac
        Try {
            Write-Host " "
            Write-Host "  Deploying [$projectName] project"
            [byte[]] $projectBytes = [System.IO.File]::ReadAllBytes("$scriptPath\$folder\$file")
            $catalogFolder.DeployProject($projectName,$projectBytes)>$null
        } Catch {
            Write-Warning "Errors raised during deployment attempt on project [$projectName]:`n$_"
            Write-Warning "In this script context, this is usually due to security constraints."
            break
        }
        
        # check for environment
        $environment = $catalogFolder.Environments[$projectName]
        Write-Host " "
                    
        if (!$environment) {
            Try {
                Write-Host "  Creating [$projectName] environment" 
                $environment = New-Object "$ISNamespace.EnvironmentInfo" ($catalogFolder,$projectName,$projectName)
                $environment.Create()
            } Catch {
                Write-Warning "Errors raised during deployment attempt on project [$projectName]:`n$_"
                Write-Warning "In this script context, this is usually due to security constraints."
                break
            }
        }
        elseif ($environment) {
            Write-Host "  Environment [$projectName] already exists" 
        }

        # instantiate project for syncing...
        $project = $catalogFolder.Projects[$projectName]
        
        # make sure project references environment  (revist this one for tightening)
        $referenceExists = $false
        foreach ($reference in $project.References) {           
           if ($reference.Name -eq $projectName) {
                $referenceExists = $true
           }
        }
        
        # if the project does not reference the environment, alter it to do so...
        if (!$referenceExists) {
        
            Try {
                Write-Host "  Referencing project to environment"
                $project.References.Add($projectName)
                $project.Alter()
            } Catch {
                Write-Warning "Errors raised during deployment attempt on project [$projectName]:`n$_"
                Write-Warning "In this script context, this is usually due to security constraints."
                break
            }
        }
        else {
            Write-Host "  Project already references environment"
        }

        # get the reference id
        $project.References.Refresh() 
        $referenceID = @($project.References | Where-Object {$_.Name -match "$projectName"})[0].ReferenceId

        # add variables
        $projectParameters = @($project.Parameters)
        
        # loop through all the 'package' paramenters, add them as variables, and tie them to the package parameter
        foreach ($projectParameter in $projectParameters) {
            
            $projectParameterName = $projectParameter.name
            $projectParameterUserDefined = $projectParameterName -match "[.]"      
            $projectParameterSensitive = $projectParameter.Sensitive
            $projectParameterDatatype = $projectParameter.Datatype            
            $projectParameterDescription = $projectParameter.Description     
            $projectParameterValue = $projectParameter.DesignDefaultValue
     
            if ("[$projectParameterValue]" -eq "[]") {$projectParameterValue=""}
     
            # check for existence
            if (!$projectParameterUserDefined) {
             
                #         
                if (!$environment.Variables["$projectParameterName"]) {
                
                    $environment.Variables.Add("$projectParameterName",      #
                                               $projectParameterDatatype,    #
                                               $projectParameterValue,       # value
                                               $projectParameterSensitive,   #
                                               $projectParameterDescription) #
                    $environment.Alter()
                    Write-Host "    Project parameter [$projectParameterName] added"     
                }
                else {
                    Write-Host "    Project parameter [$projectParameterName] already exists"
                } # if project parameter exists

                # configure the parameter with the variable
                Write-Host "      Tying parameter to variable"
                $environmentVariable = $environment.Variables["$projectParameterName"]
                $environmentVariableName = $environmentVariable.name
                $project.Parameters["$projectParameterName"].Set("Referenced","$environmentVariableName")
                $project.Alter()

            } # if user project parameter

        } # each project parameter

        # build the package
        $agent = New-Object -TypeName Microsoft.SQLServer.Management.Smo.Server($serverName)
        [string]$credName = @($agent.JobServer.ProxyAccounts| Where-Object {$_.Name -match "EnterpriseData"})[0].Name  # $credName is the proxy, this is looking up based on "EnterpriseData", change to your proxy

        # get alll the parent packages
        $parentPackages = @($project.Packages | Where-Object {$_.Name -match "-Parent"})
        $parentPackage = $parentPackages[0]

        # loop through the parent packages and build a agent job for each one...
        foreach ($parentPackage in $parentPackages) {

            # we want to grab the curly brace value, if it is not there, use default
            $start = $parentPackage.Name.indexOf("{") + 1
            $end = $parentPackage.Name.indexOf("}",$start)
            
            if ($start -lt 1 -or $end -lt 1) {
                $result = "default"
            } else {
                $length = $end - $start
                $result = $parentPackage.Name.substring($start,$length).ToLower()
            }
        
            [string]$jobNameCleaned = $parentPackage.Name.Replace(".dtsx","").Replace("-Parent","")
            [string]$jobName = "[SSIS] $folder/$jobNameCleaned"
            [string]$parentPackageName = $parentPackage.Name

            Try {
                
                # get existing job
                $job = @($agent.JobServer.Jobs | Where-Object {$_.Name -eq "$jobName"})[0]

                # if the job doesnt exist, create it
                if (!$job) {
            
                    Write-Host "  Creating [$jobName] job"    
                    $job = New-Object -TypeName Microsoft.SqlServer.Management.SMO.Agent.Job -argumentlist $agent.JobServer, $jobName
                    $job.Description = "SSIS Job to execute the $projectName project's Parent {$result} package.  This job has been created by a framework, do not alter directly."
                    $job.OwnerLoginName = "sa"
                    $job.Create()
                    $job.ApplyToTargetServer("(local)")
                    
                } else {
                    Write-Host "  Job [$jobName] found"
                    $job.JobSteps.Refresh()
                    $jobSteps = @($job.JobSteps)
             
                    foreach ($jobStep in $jobSteps) {
                        $jobStep.Drop()
                    }
                    
                } # job creation
            
            } Catch {
                Write-Warning "Errors raised during creation attempt of job [$jobName]:`n$_"
                Write-Warning "In this script context, this is usually due to security constraints."
                continue
            }
            
            # add back in all the lines
            Try {
            
                $jobStep = New-Object -TypeName Microsoft.SqlServer.Management.SMO.Agent.JobStep -argumentlist $job, "Execute proxy step."
                $jobStep.Command = "print 'start'"
                $jobStep.DatabaseName = "tempdb"
                $jobStep.OnSuccessAction = "GoToNextStep"
                $jobStep.OnFailAction = "QuitWithFailure"
                $jobStep.Create()

                $jobStepX = New-Object -TypeName Microsoft.SqlServer.Management.SMO.Agent.JobStep -argumentlist $job, "Run package '$folder/$projectName/$parentPackageName' from catalog."
                $jobStepX.subsystem = [Microsoft.SqlServer.Management.Smo.Agent.AgentSubSystem]::SSIS
                $jobStepX.Server = $serverName
                $jobStepX.ProxyName = $credName
                $jobStepX.OnSuccessAction = "QuitWithSuccess"
                $jobStepX.OnFailAction = "QuitWithFailure"            
                $jobStepX.Command = "/ISSERVER ""\""\SSISDB\$folder\$projectName\$parentPackageName\"""" /SERVER $serverName /ENVREFERENCE $referenceID /Par ""\""`$ServerOption::LOGGING_LEVEL(Int16)\"""";1 /Par ""\""`$ServerOption::SYNCHRONIZED(Boolean)\"""";True /CALLERINFO SQLAGENT /REPORTING E"                    
                $jobStepX.Create()              
            
            } Catch {
                Write-Warning "Errors raised during creation attempt on job steps for [$jobName]:`n$_"
                Write-Warning "In this script context, this is usually due to security constraints."
                continue        
            }            

        } # each package

    } # each ispac

} # each folder

Write-Host " "
Write-Host "Deployment complete and successful." 
Write-Host " "
Write-Host "Press any key to continue..."

Try {
    $x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
 } Catch {
    Write-Host " "
 }
