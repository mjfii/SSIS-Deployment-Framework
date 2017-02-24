# SSIS Deployement Framework

These PowerShell scripts deconstruct the MS SQL Server Information Services ("SSIS") Integration Services Project Deployment Files ("ISPAC") to isolate parent/child relationships within the packages, deploy to a coordinated file structure, align environment variables, and build MS SQL Server Agent Jobs.

## Motivation

Deploying SSIS ISPAC's is a redundant chore, and it leaves quite a bit of room for error with various folders, variables, and jobs across different environments - even if you have a set of deployment instructions / protocol.  This framework takes the risk of the deployment plan.

## Prerequisites

The default security level may not allow the execution of the scripts.  In order to bypass this and allow 'local' executions, run the below:

```PowerShell
set-executionpolicy remotesigned
```

Additionally, you will need administrative privileges on the machine where the script is being executed, not necessarily the destination.  However, since you are deploying to an MS SQL Server instance, you will need to have the appropriate credentials to do so, i.e. not necessarily administrative privileges.

Finally, this only works with the `project deployment` methodology.

## Installation

No installation is required.  Use the scripts as necessary to deploy ISPACs.

## Example

If the scripts are placed in the following folder structure with ISPACs in subsequent folders, then the following will be occur:

```
    |-- deployment framework.ps1
    |-- mdm
        |-- customer.ispac
        |-- product.ispac
    |-- transactional
        |-- sales.ispac
        |-- inventory.ispac
        |-- purchasing.ispac
```

1. Test whether the `system` database `SSISDB` is in place;
2. Build an `mdm` and a `transactional` folder on the `SSISDB` database, i.e. it matches the directory structure to the SSIS structure;
3. Deploy each of the ISPACs to the corresponding folders within the database as they are aligned to the directory structure;
4. For each project parameter in each ISPAC, a corresponding environment variable is created (or altered) and the package default is used; and
5. An MS SQL Server Agent Job ("Job") is created for each 'package' in each 'project' where the 'package' name contains the string '-Parent' (this can obviously be altered), and the Job references this 'package' to execute and aligns it to the environment variables noted in Step 4.

## Contributors

Michael Flanigan  
email: [mick.flanigan@gmail.com](mick.flanigan@gmail.com)  
twitter: [@mjfii](https://twitter.com/mjfii)  

# Versioning

0.0.0.9000 - Initial deployment (2017-02-10)
