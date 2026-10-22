param(
    [switch]$SkipRun,
    [switch]$LeaveRunning
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location -LiteralPath $PSScriptRoot

function Invoke-Compose {
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & docker compose @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        $tail = ($output | Select-Object -Last 25 | Out-String)
        throw "docker compose $($Arguments -join ' ') завершился с ошибкой.`n$tail"
    }
}

function BsonValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    foreach ($key in @('$numberInt', '$numberLong', '$numberDecimal')) {
        $property = $Value.PSObject.Properties[$key]
        if ($null -ne $property) { return $property.Value }
    }
    return $Value
}

function Show-Code {
    param([string]$Marker, [int]$Count)
    $start = -1
    for ($i = 0; $i -lt $script:source.Count; $i++) {
        if ($script:source[$i].Contains($Marker)) { $start = $i; break }
    }
    if ($start -lt 0) { throw "Не найден код: $Marker" }
    $end = [Math]::Min($start + $Count, $script:source.Count)
    for ($i = $start; $i -lt $end; $i++) {
        Write-Host ('{0,3}  {1}' -f ($i + 1), $script:source[$i]) -ForegroundColor Gray
    }
}

function Show-Heading {
    param([int]$Number, [string]$Title, [string]$Evidence)
    Write-Host ''
    Write-Host ('=' * 92) -ForegroundColor Cyan
    Write-Host ("  $Number/8  $Title") -ForegroundColor Cyan
    Write-Host ('=' * 92) -ForegroundColor Cyan
    Write-Host "Источник: $Evidence" -ForegroundColor DarkGray
    Write-Host ''
}

function Stock {
    param($State, [string]$Sku, [string]$Size)
    $product = @($State.products) | Where-Object { $_._id -eq $Sku } | Select-Object -First 1
    $variant = @($product.variants) | Where-Object { $_.size -eq $Size } | Select-Object -First 1
    return (BsonValue $variant.stock)
}

if (-not $SkipRun) {
    if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker не найден. Установите и запустите Docker Desktop.'
    }
    Write-Host 'Поднимаю replica set...' -ForegroundColor Cyan
    Invoke-Compose -Arguments @('up', '-d')
    Write-Host 'Выполняю полный сценарий: docker compose run --rm lab all' -ForegroundColor Cyan
    try {
        Invoke-Compose -Arguments @('run', '--rm', 'lab', 'all')
    } catch {
        if (-not $LeaveRunning) { Invoke-Compose -Arguments @('down') }
        throw
    }
}

$resultPath = Join-Path $PSScriptRoot 'results/results.json'
if (-not (Test-Path -LiteralPath $resultPath)) { throw 'Нет results/results.json. Запустите без -SkipRun.' }
$result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'solution.js') -Encoding UTF8
$hash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'solution.js') -Algorithm SHA256).Hash.ToLowerInvariant()
foreach ($scenario in @('data', 'index', 'purchase', 'failover')) {
    $case = $result.scenarios.$scenario
    if ($case.status -ne 'passed' -or $case.solutionHash -ne $hash) {
        throw "Сценарий $scenario не прошёл или результат устарел. Запустите без -SkipRun."
    }
}

$data = $result.scenarios.data.artifacts.data
$index = $result.scenarios.index.artifacts.index
$purchase = $result.scenarios.purchase.artifacts.purchase
$rollbackTx = $result.scenarios.purchase.artifacts.'transactions-rollback'.delta
$successTx = $result.scenarios.purchase.artifacts.'transactions-success'.delta
$failover = $result.scenarios.failover.artifacts.failover

try {
    Show-Heading 1 'Стенд и полный прогон' 'compose.yaml; results/results.json'
    Write-Host 'MongoDB 8.0.30; replica set hw2rs: m1, m2, m3; база hw2.'
    Write-Host 'Команда получения результатов: docker compose run --rm lab all'
    Write-Host ''
    foreach ($name in @('data', 'index', 'purchase', 'failover')) {
        $case = $result.scenarios.$name
        Write-Host ('{0,-10} {1,-6} {2,2} проверок' -f $name, $case.status, @($case.checks).Count) -ForegroundColor Green
    }
    Write-Host 'Полный фактический вывод: results/results.json (Extended JSON).'

    Show-Heading 2 'Валидатор, поиск и история' 'solution.js; scenarios.data.artifacts.data'
    Show-Code 'globalThis.installValidator' 12
    Write-Host ''
    Show-Code 'globalThis.searchProducts' 4
    Show-Code 'globalThis.historyCursor' 4
    Write-Host ''
    foreach ($v in $data.validation) {
        Write-Host ('{0,-16} код {1}' -f $v.id, (BsonValue $v.code)) -ForegroundColor Yellow
    }
    Write-Host ('Поиск clothes/L/2: {0}' -f (($data.searches[0].found) -join ', ')) -ForegroundColor Yellow
    Write-Host ('После A/L=2: {0}' -f (($data.searches[-1].found) -join ', ')) -ForegroundColor Yellow
    Write-Host ('История userId=2500, paid: {0} заказов; первые {1}' -f @($data.historyIds).Count, (($data.historyIds | Select-Object -First 4) -join ', ')) -ForegroundColor Yellow

    Show-Heading 3 'Отчёт о продажах' 'solution.js; scenarios.data.artifacts.data.report'
    Show-Code 'globalThis.report' 17
    Write-Host ''
    Write-Host 'paid, [2026-01-01, 2026-02-01):' -ForegroundColor Yellow
    foreach ($row in $data.report) {
        Write-Host ('{0}  {1,-12} qty={2}  revenue={3}' -f $row.sku, $row.name, (BsonValue $row.qty), (BsonValue $row.revenue)) -ForegroundColor Yellow
    }
    Write-Host 'A: 2 x 100.00 + 1 x 120.00 = 320.00; смена цены в каталоге результат не изменила.'

    Show-Heading 4 'Индекс и план выполнения' 'solution.js; scenarios.index.artifacts.index, explain-before/after'
    Show-Code 'globalThis.historyIndex' 3
    Write-Host ''
    Write-Host 'На неизменном наборе из 10 000 заказов:' -ForegroundColor Yellow
    Write-Host ('{0,-21} {1,10} {2,10}' -f 'Метрика', 'До', 'После')
    foreach ($name in @('nReturned', 'totalKeysExamined', 'totalDocsExamined')) {
        Write-Host ('{0,-21} {1,10} {2,10}' -f $name, (BsonValue $index.before.$name), (BsonValue $index.after.$name)) -ForegroundColor Yellow
    }
    Write-Host ('{0,-21} {1,10} {2,10}' -f 'Отдельная SORT', $index.before.hasSORT, $index.after.hasSORT) -ForegroundColor Yellow
    Write-Host 'До: COLLSCAN + SORT. После: IXSCAN. ID и порядок совпали; hint не применялся.'

    Show-Heading 5 'Покупка: реальный откат' 'solution.js; scenarios.purchase.artifacts.purchase.rollback'
    Show-Code 'for (const {sku, size, qty}' 14
    Write-Host ''
    foreach ($event in $purchase.rollback.trace) {
        Write-Host ('{0}: matched={1}, modified={2}' -f $event.sku, (BsonValue $event.matched), (BsonValue $event.modified)) -ForegroundColor Yellow
    }
    Write-Host ('Ошибка: {0}' -f $purchase.rollback.error) -ForegroundColor Yellow
    Write-Host ('A/M: {0} -> {1}; B/L: {2} -> {3}; заказов: {4}' -f (Stock $purchase.rollback.before 'A' 'M'), (Stock $purchase.rollback.after 'A' 'M'), (Stock $purchase.rollback.before 'B' 'L'), (Stock $purchase.rollback.after 'B' 'L'), @($purchase.rollback.after.orders).Count) -ForegroundColor Yellow
    Write-Host ('Счётчики: started +{0}, committed +{1}, aborted +{2}' -f (BsonValue $rollbackTx.totalStarted), (BsonValue $rollbackTx.totalCommitted), (BsonValue $rollbackTx.totalAborted)) -ForegroundColor Yellow

    Show-Heading 6 'Покупка: успех, повтор и конфликт' 'scenarios.purchase.artifacts.purchase'
    Show-Code 'const previous = await c.orders.findOne' 10
    Write-Host ''
    Show-Code 'const order = {_id: request.operationId' 4
    Write-Host ''
    Write-Host ('Создан заказ {0}, status={1}, items={2}' -f $purchase.success.order._id, $purchase.success.order.status, @($purchase.success.order.items).Count) -ForegroundColor Yellow
    Write-Host ('A/M= {0}; B/L= {1}' -f (Stock $purchase.success.state 'A' 'M'), (Stock $purchase.success.state 'B' 'L')) -ForegroundColor Yellow
    Write-Host ('Счётчики: started +{0}, committed +{1}, aborted +{2}' -f (BsonValue $successTx.totalStarted), (BsonValue $successTx.totalCommitted), (BsonValue $successTx.totalAborted)) -ForegroundColor Yellow
    Write-Host ('Повтор вернул тот же заказ: {0}; конфликт: {1}' -f ($purchase.replay.order._id -eq $purchase.success.order._id), $purchase.conflict.error) -ForegroundColor Yellow

    Show-Heading 7 'Смена primary' 'solution.js; scenarios.failover.artifacts.failover'
    Show-Code 'globalThis.writeProbe' 9
    Write-Host ''
    Write-Host ('До: {0}' -f ((@($failover.before) | ForEach-Object { "$($_.host)=$($_.role)" }) -join ', ')) -ForegroundColor Yellow
    Write-Host ('Первая запись подтверждена: {0}' -f $failover.firstWrite.acknowledged) -ForegroundColor Yellow
    Write-Host ('После: {0}' -f ((@($failover.after) | ForEach-Object { "$($_.host)=$($_.role)" }) -join ', ')) -ForegroundColor Yellow
    Write-Host ('Старый документ прочитан: {0}' -f $failover.read.message) -ForegroundColor Yellow
    Write-Host ('Новая запись подтверждена: {0}; тот же клиент: {1}' -f $failover.newWrite.acknowledged, $failover.sameClient) -ForegroundColor Yellow

    Show-Heading 8 'Шардирование и итог' 'README.md; results/results.json'
    Write-Host 'Ключ шардирования orders: {userId: 1}.'
    Write-Host 'История userId=2500 -> шард B (диапазон [2000, 5000)).' -ForegroundColor Yellow
    Write-Host 'Общий отчёт по status=paid -> шарды A и B.' -ForegroundColor Yellow
    Write-Host 'Индекс {status: 1} ускоряет локальный отбор, но не меняет маршрут.'
    Write-Host ''
    Write-Host 'Все 4 сценария прошли; код: solution.js; полный вывод: results/results.json.' -ForegroundColor Green
} finally {
    if (-not $SkipRun -and -not $LeaveRunning) {
        Write-Host 'Останавливаю стенд: docker compose down' -ForegroundColor Cyan
        Invoke-Compose -Arguments @('down')
    }
}
