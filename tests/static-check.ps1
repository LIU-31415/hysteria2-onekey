$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'hysteria.sh'
$content = [IO.File]::ReadAllText($scriptPath)
$bytes = [IO.File]::ReadAllBytes($scriptPath)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-True ($content.StartsWith("#!/usr/bin/env bash`n")) 'hysteria.sh 缺少 Bash shebang 或不是 LF 换行。'
Assert-True (-not ($bytes -contains 13)) 'hysteria.sh 包含 CRLF。'

$functionNames = [regex]::Matches($content, '(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\)') |
    ForEach-Object { $_.Groups[1].Value }
$duplicates = $functionNames | Group-Object | Where-Object Count -gt 1
Assert-True ($null -eq $duplicates) "存在重复函数：$($duplicates.Name -join ', ')"

$required = @(
    'https://get.hy2.sh/',
    '--certificate-profile shortlived',
    '--keylength ec-256',
    '--days -3',
    'pinSHA256',
    'ipv4Exclude',
    'ipv6Exclude',
    'CapabilityBoundingSet=CAP_NET_BIND_SERVICE',
    'listen: :${SERVER_PORT}',
    "od -An -v -tx1",
    'rollback_transaction',
    'ensure_cron_available',
    'HY2_TEST_MODE',
    'hysteria_core_owned',
    'ensure_install_scope_safe',
    'managed_paths_are_safe',
    'remove_managed_data_files',
    '脚本不会修改防火墙',
    '有效安装状态，拒绝删除可能由其他方式创建的 Hysteria',
    '请输入 UNINSTALL 确认'
)
foreach ($text in $required) {
    Assert-True ($content.Contains($text)) "缺少关键实现：$text"
}

$forbidden = @(
    'chmod o+r',
    'iptables-persistent',
    'iptables',
    'ip6tables',
    'firewall-cmd',
    'ufw ',
    'nftables',
    '--firewall-apply',
    'CAP_NET_ADMIN',
    'CAP_NET_RAW',
    'PORT_MODE',
    'PORT_START',
    'PORT_END',
    '20000-30000',
    'SCRIPT_URL',
    'update_script()',
    'mport=',
    "sed '/--cron/d' /etc/crontab",
    'curl -fsSL https://get.hy2.sh/ | bash'
)
foreach ($text in $forbidden) {
    Assert-True (-not $content.Contains($text)) "发现不安全或过时实现：$text"
}

Write-Output 'Static checks passed.'
