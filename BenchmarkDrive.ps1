﻿param (
    [Parameter(Mandatory = $true)][string]$drive,
    [string]$batchId=(Get-Date -format "yyyy-MM-dd_HH-mm-ss"), # 'u' and 's' will have colons, which is bad for filenames
    [string]$testSize='10M',
    [int]$durationSec=5, # less than 5sec gave zero results
    [int]$warmupSec=0,
    [int]$cooldownSec=0,
    [int]$restSec=1,
    #todo: add search logic for diskspd
    #[string]$diskspd='%ProgramFiles%\diskspd.exe'
    [string]$diskspd='.\diskspd.exe'
#todo: add usage
# A parameter cannot be found that matches parameter name 'filesize'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Version = "0.2.1"

# get test summary object
# assume one target and one timespan
function measure-performance {
    param ( $test, $xmlFilePath, $driveObj )
    $x = [xml](Get-Content $xmlFilePath)
    $o = New-Object psobject
    # test meta data
    Add-Member -InputObject $o -MemberType noteproperty -Name 'ComputerName' -Value $x.Results.System.ComputerName
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Drive' -Value $driveObj.name
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Drive VolumeLabel' -Value $driveObj.VolumeLabel
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Batch' -Value $batchId
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Test Time' -Value (Get-Date)
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Test Name' -Value $test.name
    # io meta data
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Test File Size' -Value $testSize
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Duration [s]' -Value $durationSec
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Warmup [s]' -Value $warmupSec
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Cooldown [s]' -Value $cooldownSec
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Test Params' -Value $test.params
    # io metrics
    Add-Member -InputObject $o -MemberType noteproperty -Name 'TestTimeSeconds' -Value $x.Results.TimeSpan.TestTimeSeconds
    Add-Member -InputObject $o -MemberType noteproperty -Name 'WriteRatio' -Value ($x.Results.Profile.TimeSpans.TimeSpan.Targets.Target.WriteRatio | Select-Object -first 1)
    Add-Member -InputObject $o -MemberType noteproperty -Name 'ThreadCount' -Value $x.Results.TimeSpan.ThreadCount
    Add-Member -InputObject $o -MemberType noteproperty -Name 'RequestCount' -Value ($x.Results.Profile.TimeSpans.TimeSpan.Targets.Target.RequestCount | Select-Object -first 1)
    Add-Member -InputObject $o -MemberType noteproperty -Name 'BlockSize' -Value ($x.Results.Profile.TimeSpans.TimeSpan.Targets.Target.BlockSize | Select-Object -first 1)

    # sum read and write iops across all threads and targets
    $ri = ($x.Results.TimeSpan.Thread.Target |
            Measure-Object -sum -Property ReadCount).Sum
    $wi = ($x.Results.TimeSpan.Thread.Target |
            Measure-Object -sum -Property WriteCount).Sum
    $rb = ($x.Results.TimeSpan.Thread.Target |
            Measure-Object -sum -Property ReadBytes).Sum
    $wb = ($x.Results.TimeSpan.Thread.Target |
            Measure-Object -sum -Property WriteBytes).Sum
    Add-Member -InputObject $o -MemberType noteproperty -Name 'ReadCount' -Value $ri
    Add-Member -InputObject $o -MemberType noteproperty -Name 'WriteCount' -Value $wi
    Add-Member -InputObject $o -MemberType noteproperty -Name 'ReadBytes' -Value $rb
    Add-Member -InputObject $o -MemberType noteproperty -Name 'WriteBytes' -Value $wb

    # latency
    $l = @(); foreach ($i in 25,50,75,90,95,99,99.9,100) { $l += ,[string]$i }
    $h = @{}; $x.Results.TimeSpan.Latency.Bucket |ForEach-Object { $h[$_.Percentile] = $_ } # AY, hash all percentiles in $h
 
 # todo: seems unused code, to be confirmed!!!
        #todo: only when comfirmed, fix error 
        # ForEach-Object: Z:\DiskSpdAuto\BenchmarkDrive.ps1:60
        # Line |
        #   60 |      $l |ForEach-Object {
        #      |          ~~~~~~~~~~~~~~~~
        #      | The property 'WriteMilliseconds' cannot be found on this object. Verify that the property exists.

    # $l |ForEach-Object {
    #     #$b = $h[$_];
    #     $b = $h[$_]
    #     #Add-Member -InputObject $o -MemberType noteproperty -Name ('{0}% r' -f $_) -Value $b.ReadMilliseconds
    #     #Add-Member -InputObject $o -MemberType noteproperty -Name ('{0}% w' -f $_) -Value $b.WriteMilliseconds
    # }

    return $o
}

function measure-performances {
    param ( $tests )

    $o = New-Object psobject

    # drive meta data
    Add-Member -InputObject $o -MemberType noteproperty -Name 'ComputerName' -Value $tests[0].ComputerName
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Drive' -Value $tests[0].Drive
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Drive VolumeLabel' -Value $tests[0].'Drive VolumeLabel'
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Batch' -Value $tests[0].Batch
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Test Time' -Value $tests[0].'Test Time'
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Test File Size' -Value $tests[0].'Test File Size'
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Test Duration [s]' -Value $tests[0].'Duration [s]'

    # io
    #round calculation result to [decimal] with 1 digit
    [decimal]$v=0

    $t_sr=$tests |Where-Object {$_.'Test Name' -eq 'Sequential read'}
    $v=([Math]::Round([decimal]($t_sr.ReadBytes/$t_sr.TestTimeSeconds/1024/1024),1))
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Sequential Read  1MB     [MB/s]' -Value $v

    $t_sw=$tests |Where-Object {$_.'Test Name' -eq 'Sequential write'}
    $v=([Math]::Round([decimal]($t_sw.WriteBytes/$t_sw.TestTimeSeconds/1024/1024),1))
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Sequential Write 1MB     [MB/s]' -Value $v

    $t_rr=$tests |Where-Object {$_.'Test Name' -eq 'Random read'}
    $v=([Math]::Round([decimal]($t_rr.ReadBytes/$t_rr.TestTimeSeconds/1024/1024),1))
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Random Read  4KB (QD=1)  [MB/s]' -Value $v

    $t_rw=$tests |Where-Object {$_.'Test Name' -eq 'Random write'}
    $v=([Math]::Round([decimal]($t_rw.WriteBytes/$t_rw.TestTimeSeconds/1024/1024),1))
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Random Write 4KB (QD=1)  [MB/s]' -Value $v

    $t_r2r=$tests |Where-Object {$_.'Test Name' -eq 'Random QD32 read'}
    $v=([Math]::Round([decimal]($t_r2r.ReadBytes/$t_r2r.TestTimeSeconds/1024/1024),1))
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Random Read  4KB (QD=32) [MB/s]' -Value $v

    $t_r2w=$tests |Where-Object {$_.'Test Name' -eq 'Random QD32 write'}
    $v=([Math]::Round([decimal]($t_r2w.WriteBytes/$t_r2w.TestTimeSeconds/1024/1024),1))
    Add-Member -InputObject $o -MemberType noteproperty -Name 'Random Write 4KB (QD=32) [MB/s]' -Value $v

    return $o
}

####################################
# Main
####################################
# check environment
# 1. check $drive exist, else abort
# todo: handle other drive parameter values 'a', 'a:', 'a:\'
if (test-path -Path $drive){
    # passed drive exist
} else {
    Write-Error "parameter 'drive' does not exist or is not accessible - $Drive"
}

# 2. check $diskspd exist, else abort
if (test-path -Path $diskspd -PathType leaf){
    # passed diskspd exist
} else {
    Write-Error "parameter 'diskspd' does not exist, aborting - $diskspd"
}

$testFileParams="${drive}benchmark.${batchId}.tmp" 
# 3. check testFileParams does NOT exists
if (test-path -Path $testFileParams -PathType leaf){
    Write-Error "parameter 'testFileParams' already exists, aborting - $testFileParams"
}
# initialize test file
# consider "fsutil file createnew <name of file> <size in bytes>" though can't control caching or content
# best to do one per drive and not each test. also, had effect on "test duration" when was part of the test.
$diskspdOutputFile=('{0}-Generation.xml' -f $batchId);
# run benchmark program
$params=( ('-Rxml -d1 -S -Z1M -c{0}' -f $testSize) ,$testFileParams) -join ' ';
# make sure to write with cache disabled, or else on slow systems this will exit with data still writing from cache to disk.
Write-Host "Running Benchmark program:$diskspd" `
    " - parameters:$params" `
    " - outputfile:$diskspdOutputFile"

# todo: convert to function with error checks
& $diskspd ($params -split ' ') > $diskspdOutputFile

# fixed params for next tests
$fixedParams='-L -S -Rxml'

# batch auto params
$batchAutoParam='-d{0} -W{1} -C{2}' -f $durationSec, $warmupSec, $cooldownSec

# iterate over tests
$tests=@()
foreach ($test in @{name='Sequential read'; params='-b1M -o1 -t1 -w0 -Z1M'},
    @{name='Sequential write'; params='-b1M -o1 -t1 -w100 -Z1M'},
    @{name='Random read'; params='-b4K -o1 -t1 -r -w0 -Z1M'},
    @{name='Random write'; params='-b4K -o1 -t1 -r -w100 -Z1M'},
    @{name='Random QD32 read'; params='-b4K -o32 -t1 -r -w0 -Z1M'},
    @{name='Random QD32 write'; params='-b4K -o32 -t1 -r -w100 -Z1M'}
    <# todo: verify why this was commented out
    ,
    @{name='Random T32 read'; params='-b4k -o1 -t32 -r -w0 -Z1M'},
    @{name='Random T32 write'; params='-b4k -o1 -t32 -r -w100 -Z1M'}
    #>
    ) {
        # run test
        $params=($fixedParams,$batchAutoParam,$test.params,$testFileParams) -join ' ';
        $diskspdOutputFile=('{0}-{1}.xml' -f $batchId, $test.name);
        Write-Host $params
        Write-Host $diskspdOutputFile
        Start-Sleep $restSec # sleep a sec to calm down IO
        # todo: convert to function with error checks
        & $diskspd ($params -split ' ') > $diskspdOutputFile

        # read result and write to batch file
        $driveObj=[System.IO.DriveInfo]::GetDrives() | Where-Object {$_.Name -eq $drive }
        $testResult=measure-performance $test $diskspdOutputFile $driveObj
        
        $diskspdOutputCsvFile = "${batchId}-BenchMarkResults.csv"
        $testResult | Export-Csv $diskspdOutputCsvFile -NoTypeInformation -Append
        $tests+=$testResult
}

# sum drive tests to a single row
$testsSum = measure-performances $tests
$testsSum 
$diskspdOutputCsvFileSummary = "BenchMarkResultsSummarized.csv"
$testsSum | Export-Csv $diskspdOutputCsvFileSummary -NoTypeInformation -Append
# display name of output csv files
Write-Host "Benchmark results for this run: $diskspdOutputCsvFile" 
Write-Host "Summary of all benchmark results: $diskspdOutputCsvFileSummary" 

Remove-Item -Path $testFileParams
# 