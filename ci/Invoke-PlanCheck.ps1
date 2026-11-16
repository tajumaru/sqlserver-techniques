<#
.SYNOPSIS
    対象クエリを実行して実際の実行プランを取り、インデックスの効き方を判定する。

.DESCRIPTION
    ci/targets/*.sql を SET STATISTICS XML ON 付きで実行し、プラン XML に対して
    次のルールで合否を出す（閾値は ci/plan-check.config.json）:
      - Clustered Index Scan / Table Scan / Index Scan が出たら失敗
        （allowScanTables に挙げたテーブルは除く）
      - Key Lookup / RID Lookup が maxLookups を超えたら失敗
      - PlanAffectingConvert（ConvertIssue = 'Seek Plan'）が出たら失敗（暗黙変換で Seek が落ちている）
    1件でも失敗したら終了コード 1。

    接続先は環境変数で渡す: SQLSERVER_HOST, SQLSERVER_DB, SQLSERVER_USER, SQLSERVER_PASSWORD
#>
[CmdletBinding()]
param(
    [string]$TargetsDir = "$PSScriptRoot/targets",
    [string]$ConfigPath = "$PSScriptRoot/plan-check.config.json"
)

$ErrorActionPreference = 'Stop'

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$allowScan = @($config.allowScanTables)
$maxLookups = [int]$config.maxLookups

$conn = @{
    ServerInstance = $env:SQLSERVER_HOST
    Database       = $env:SQLSERVER_DB
    Username       = $env:SQLSERVER_USER
    Password       = $env:SQLSERVER_PASSWORD
    TrustServerCertificate = $true
}

$ns = @{ sp = 'http://schemas.microsoft.com/sqlserver/2004/07/showplan' }
$failed = $false

foreach ($file in Get-ChildItem $TargetsDir -Filter *.sql | Sort-Object Name) {
    $sql = Get-Content $file.FullName -Raw
    # STATISTICS XML はプランを追加の結果セットとして返すので、
    # ShowPlanXML を含むセルを全テーブルから探す
    $ds = Invoke-Sqlcmd @conn -Query "SET STATISTICS XML ON;`n$sql" -OutputAs DataSet
    $planText = $null
    foreach ($table in $ds.Tables) {
        if ($table.Rows.Count -gt 0) {
            $cell = [string]$table.Rows[0][0]
            if ($cell -like '*ShowPlanXML*') { $planText = $cell }
        }
    }
    if (-not $planText) {
        Write-Host "FAIL $($file.Name): プラン XML を取得できなかった"
        $failed = $true
        continue
    }

    $plan = [xml]$planText
    $problems = @()

    $scanOps = Select-Xml -Xml $plan -XPath "//sp:RelOp[@PhysicalOp='Clustered Index Scan' or @PhysicalOp='Table Scan' or @PhysicalOp='Index Scan']" -Namespace $ns
    foreach ($node in $scanOps) {
        $tableName = $null
        $objNode = Select-Xml -Xml $node.Node -XPath "*/sp:Object" -Namespace $ns | Select-Object -First 1
        if ($objNode) { $tableName = $objNode.Node.GetAttribute('Table') }
        if ($allowScan -notcontains $tableName) {
            $problems += "Scan: $($node.Node.GetAttribute('PhysicalOp')) on $tableName"
        }
    }

    $lookups = @(Select-Xml -Xml $plan -XPath "//sp:RelOp[@PhysicalOp='Key Lookup' or @PhysicalOp='RID Lookup']" -Namespace $ns)
    if ($lookups.Count -gt $maxLookups) {
        $problems += "Lookup: $($lookups.Count) 件（上限 $maxLookups）"
    }

    $converts = @(Select-Xml -Xml $plan -XPath "//sp:PlanAffectingConvert[@ConvertIssue='Seek Plan']" -Namespace $ns)
    foreach ($c in $converts) {
        $problems += "Implicit conversion (Seek Plan): $($c.Node.GetAttribute('Expression'))"
    }

    if ($problems.Count -gt 0) {
        $failed = $true
        Write-Host "FAIL $($file.Name)"
        $problems | ForEach-Object { Write-Host "  - $_" }
    } else {
        Write-Host "PASS $($file.Name)"
    }
}

if ($failed) { exit 1 }
