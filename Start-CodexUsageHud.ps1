param(
  [string]$NodeExe = "",
  [string]$BackendScript = "",
  [string]$StatusPath = "",
  [switch]$NoBackend
)

$ErrorActionPreference = "Stop"
$createdNew = $false
$script:SingleInstanceMutex = [System.Threading.Mutex]::new($true, "Local\CodexUsageHud", [ref]$createdNew)
if (-not $createdNew) { exit 0 }
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BackendScript) { $BackendScript = Join-Path $script:Root "backend.js" }
if (-not $StatusPath) { $StatusPath = Join-Path $script:Root "status.json" }
$script:SettingsPath = Join-Path $script:Root "hud-settings.json"

$labelBase64 = "eyJ0aXRsZSI6IkNvZGV4IOeUqOmHjyIsImNvbm5lY3RpbmciOiLov57mjqXkuK0uLi4iLCJjb25uZWN0ZWQiOiLlt7Lov57mjqUiLCJkaXNjb25uZWN0ZWQiOiLmnKrov57mjqUiLCJyZWFsIjoi55yf5a6eIiwiZXN0aW1hdGUiOiLkvLDnrpciLCJxdW90YSI6IuWJqeS9memineW6piIsInByaW1hcnkiOiI15bCP5pe2Iiwic2Vjb25kYXJ5IjoiN+WkqSIsInRvZGF5Ijoi5LuK5pelIFRva2VuIiwibGlmZXRpbWUiOiLntK/orqEgVG9rZW4iLCJjb250ZXh0Ijoi5LiK5LiL5paHIiwicmVjZW50VGhyZWFkIjoi5pyA6L+R57q/56iLIiwidXBkYXRlZCI6IuabtOaWsOaXtumXtCIsInNvdXJjZSI6IuaVsOaNrua6kCIsIm5vRGF0YSI6IuaXoOaVsOaNriIsIm5vVGhyZWFkVG9rZW4iOiLmnKrmlLbliLDnur/nqIsgdG9rZW4g6YCa55+lIiwiYWNjb3VudCI6Iui0puaItyIsInBsYW4iOiLorqHliJIiLCJjbG9zZSI6IuWFs+mXrSIsInJlZnJlc2giOiLliLfmlrAiLCJlcnJvciI6IumUmeivryIsInJldHJ5aW5nIjoi6YeN6K+V5LitIiwiY3JlZGl0cyI6IumineWklumineW6piIsImxpbWl0Ijoi6aKd5bqmIiwidXNlZCI6IuW3sueUqCIsImxlZnQiOiLliankvZkiLCJyZXNldCI6IumHjee9riIsIndpbmRvdyI6Iueql+WPoyIsInNwYXJrIjoiU3Bhcmvpop3luqYifQ=="
$script:L = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($labelBase64)) | ConvertFrom-Json
$script:L.recentThread = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("5b2T5YmN57q/56iL"))
$script:Sep = [string][char]0x00B7

function Resolve-NodeExe {
  param([string]$Preferred)
  if ($Preferred -and (Test-Path -LiteralPath $Preferred)) { return $Preferred }

  $candidates = @(
    (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe")
  )

  $runtimeRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node"
  if (Test-Path -LiteralPath $runtimeRoot) {
    $runtimeNodes = Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName "bin\node.exe" }
    $candidates += $runtimeNodes
  }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }

  $command = Get-Command node -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  throw "Node.js was not found. Set -NodeExe to a valid node.exe."
}

function Start-HudBackend {
  if ($NoBackend) { return }
  if ($script:BackendProcess -and -not $script:BackendProcess.HasExited) { return }

  $script:ResolvedNode = Resolve-NodeExe $NodeExe
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $script:ResolvedNode
  $psi.Arguments = '"' + $BackendScript + '" "' + $StatusPath + '"'
  $psi.WorkingDirectory = $script:Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables["CODEX_HUD_POLL_MS"] = "5000"
  $script:BackendProcess = [Diagnostics.Process]::Start($psi)
}

function New-Brush {
  param([string]$Color)
  return ([System.Windows.Media.BrushConverter]::new()).ConvertFromString($Color)
}

function New-Text {
  param(
    [string]$Text,
    [double]$Size = 12,
    [string]$Color = "#DDE6EA",
    [string]$Weight = "Normal"
  )
  $tb = [System.Windows.Controls.TextBlock]::new()
  $tb.Text = $Text
  $tb.FontSize = $Size
  $tb.FontFamily = "Microsoft YaHei UI"
  $tb.Foreground = New-Brush $Color
  $tb.FontWeight = $Weight
  $tb.TextTrimming = "CharacterEllipsis"
  $tb.TextWrapping = "NoWrap"
  return $tb
}

function New-Meter {
  param([string]$Caption)
  $panel = [System.Windows.Controls.StackPanel]::new()
  $panel.Margin = "0,4,0,0"

  $top = [System.Windows.Controls.Grid]::new()
  $top.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
  $rightCol = [System.Windows.Controls.ColumnDefinition]::new()
  $rightCol.Width = "Auto"
  $top.ColumnDefinitions.Add($rightCol) | Out-Null

  $captionText = New-Text $Caption 10.5 "#91A0A6" "SemiBold"
  $valueText = New-Text $script:L.noData 10.5 "#EEF5F7" "SemiBold"
  [System.Windows.Controls.Grid]::SetColumn($valueText, 1)
  $top.Children.Add($captionText) | Out-Null
  $top.Children.Add($valueText) | Out-Null

  $bar = [System.Windows.Controls.ProgressBar]::new()
  $bar.Minimum = 0
  $bar.Maximum = 100
  $bar.Height = 5
  $bar.Value = 0
  $bar.Margin = "0,3,0,0"
  $bar.Background = New-Brush "#263039"
  $bar.Foreground = New-Brush "#20D6A2"
  $bar.BorderBrush = New-Brush "#263039"

  $hint = New-Text "" 9 "#86939A"
  $hint.Margin = "0,2,0,0"

  $panel.Children.Add($top) | Out-Null
  $panel.Children.Add($bar) | Out-Null
  $panel.Children.Add($hint) | Out-Null
  return @{ Panel = $panel; Caption = $captionText; Value = $valueText; Bar = $bar; Hint = $hint }
}

function Clamp-Percent {
  param($Value)
  if ($null -eq $Value) { return 0 }
  $n = [double]$Value
  if ($n -lt 0) { return 0 }
  if ($n -gt 100) { return 100 }
  return $n
}

function Format-Number {
  param($Value)
  if ($null -eq $Value) { return $script:L.noData }
  try { return ("{0:N0}" -f [double]$Value) } catch { return [string]$Value }
}

function Format-Reset {
  param($UnixSeconds)
  if ($null -eq $UnixSeconds) { return $script:L.noData }
  try {
    $target = [DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixSeconds).ToLocalTime().DateTime
    $span = $target - (Get-Date)
    $targetText = $target.ToString("yyyy-MM-dd HH:mm:ss")
    if ($span.TotalSeconds -le 0) { return ($script:L.retrying + " (" + $targetText + ")") }
    if ($span.TotalDays -ge 1) {
      $remaining = ("{0:N0}d {1:N0}h" -f [Math]::Floor($span.TotalDays), $span.Hours)
    } elseif ($span.TotalHours -ge 1) {
      $remaining = ("{0:N0}h {1:N0}m" -f [Math]::Floor($span.TotalHours), $span.Minutes)
    } else {
      $remaining = ("{0:N0}m" -f [Math]::Max(1, [Math]::Floor($span.TotalMinutes)))
    }
    return ($remaining + " (" + $targetText + ")")
  } catch {
    return $script:L.noData
  }
}

function Format-ResetCompact {
  param($UnixSeconds)
  if ($null -eq $UnixSeconds) { return $script:L.noData }
  try {
    $target = [DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixSeconds).ToLocalTime().DateTime
    $span = $target - (Get-Date)
    $targetText = $target.ToString("MM-dd HH:mm")
    if ($span.TotalSeconds -le 0) { return ($script:L.retrying + " > " + $targetText) }
    if ($span.TotalDays -ge 1) {
      $remaining = ("{0:N0}d {1:N0}h" -f [Math]::Floor($span.TotalDays), $span.Hours)
    } elseif ($span.TotalHours -ge 1) {
      $remaining = ("{0:N0}h {1:N0}m" -f [Math]::Floor($span.TotalHours), $span.Minutes)
    } else {
      $remaining = ("{0:N0}m" -f [Math]::Max(1, [Math]::Floor($span.TotalMinutes)))
    }
    return ($remaining + " > " + $targetText)
  } catch {
    return $script:L.noData
  }
}
function Format-LocalDateTime {
  param($Value)
  if ($null -eq $Value) { return $script:L.noData }
  try {
    return ([DateTimeOffset]::Parse([string]$Value)).ToLocalTime().DateTime.ToString("yyyy-MM-dd HH:mm:ss")
  } catch {
    return (Shorten ([string]$Value) 24)
  }
}

function Format-LocalDateTimeShort {
  param($Value)
  if ($null -eq $Value) { return $script:L.noData }
  try {
    return ([DateTimeOffset]::Parse([string]$Value)).ToLocalTime().DateTime.ToString("MM-dd HH:mm:ss")
  } catch {
    return (Shorten ([string]$Value) 14)
  }
}
function Set-MeterValue {
  param($Meter, [string]$Caption, $Window)
  $Meter.Caption.Text = $Caption
  if ($null -eq $Window) {
    $Meter.Value.Text = $script:L.noData
    $Meter.Bar.Value = 0
    $Meter.Hint.Text = ""
    return
  }

  $used = Clamp-Percent $Window.usedPercent
  $left = [Math]::Max(0, 100 - $used)
  $Meter.Bar.Value = $used
  if ($used -ge 90) {
    $Meter.Bar.Foreground = New-Brush "#FF5C5C"
  } elseif ($used -ge 70) {
    $Meter.Bar.Foreground = New-Brush "#FFB545"
  } else {
    $Meter.Bar.Foreground = New-Brush "#20D6A2"
  }

  $Meter.Value.Text = ("{0:N0}% {1}" -f $left, $script:L.left)
  $Meter.Hint.Text = ("{0:N0}% {1} {3} {2}" -f $used, $script:L.used, (Format-ResetCompact $Window.resetsAt), $script:Sep)
  $Meter.Hint.ToolTip = ("{0}: {1}" -f $script:L.reset, (Format-Reset $Window.resetsAt))
}

function Get-PropValue {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $prop = $Object.PSObject.Properties[$Name]
  if ($prop) { return $prop.Value }
  return $null
}

function Shorten {
  param([string]$Text, [int]$Max = 42)
  if (-not $Text) { return $script:L.noData }
  if ($Text.Length -le $Max) { return $Text }
  return $Text.Substring(0, $Max - 1) + "..."
}

function Read-HudSettings {
  try {
    if (Test-Path -LiteralPath $script:SettingsPath) {
      return ([System.IO.File]::ReadAllText($script:SettingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
  } catch {}
  return $null
}

function Save-HudSettings {
  try {
    if ($null -eq $window) { return }
    $settings = [ordered]@{
      left = [Math]::Round([double]$window.Left, 0)
      top = [Math]::Round([double]$window.Top, 0)
      width = [Math]::Round([double]$window.Width, 0)
      height = [Math]::Round([double]$window.Height, 0)
      updatedAt = (Get-Date).ToString("o")
    }
    $json = $settings | ConvertTo-Json -Depth 4
    $tmp = "$script:SettingsPath.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $script:SettingsPath -Force
  } catch {}
}

function Set-InitialWindowPosition {
  param($Window)
  $settings = Read-HudSettings
  $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $hasSavedPosition = $false
  if ($settings -and $null -ne $settings.left -and $null -ne $settings.top) {
    $left = [double]$settings.left
    $top = [double]$settings.top
    if ($left -gt ($screen.Left - $Window.Width + 40) -and
        $left -lt ($screen.Right - 40) -and
        $top -gt ($screen.Top - 40) -and
        $top -lt ($screen.Bottom - 40)) {
      $Window.Left = $left
      $Window.Top = $top
      $hasSavedPosition = $true
    }
  }
  if (-not $hasSavedPosition) {
    $primary = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $Window.Left = $primary.Right - $Window.Width - 24
    $Window.Top = $primary.Top + 72
  }
}
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

Start-HudBackend

$window = [System.Windows.Window]::new()
$window.Title = $script:L.title
$window.Width = 320
$window.Height = 214
$window.ResizeMode = "NoResize"
$window.WindowStyle = "None"
$window.AllowsTransparency = $true
$window.Background = "Transparent"
$window.Topmost = $true
$window.ShowInTaskbar = $true

Set-InitialWindowPosition $window

$outer = [System.Windows.Controls.Border]::new()
$outer.CornerRadius = "8"
$outer.Background = New-Brush "#F0111518"
$outer.BorderBrush = New-Brush "#334DE3C1"
$outer.BorderThickness = "1"
$outer.Padding = "10"
$shadow = [System.Windows.Media.Effects.DropShadowEffect]::new()
$shadow.Color = [System.Windows.Media.Colors]::Black
$shadow.Direction = 270
$shadow.ShadowDepth = 6
$shadow.BlurRadius = 18
$shadow.Opacity = 0.38
$outer.Effect = $shadow

$layout = [System.Windows.Controls.StackPanel]::new()
$outer.Child = $layout

$header = [System.Windows.Controls.Grid]::new()
$header.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
$statusCol = [System.Windows.Controls.ColumnDefinition]::new()
$statusCol.Width = "Auto"
$header.ColumnDefinitions.Add($statusCol) | Out-Null
$closeCol = [System.Windows.Controls.ColumnDefinition]::new()
$closeCol.Width = "Auto"
$header.ColumnDefinitions.Add($closeCol) | Out-Null

$title = New-Text $script:L.title 14 "#F4FBF8" "Bold"
$script:StatusText = New-Text $script:L.connecting 10.5 "#9DEBD8" "SemiBold"
$script:StatusText.Margin = "0,1,8,0"
[System.Windows.Controls.Grid]::SetColumn($script:StatusText, 1)

$closeButton = [System.Windows.Controls.Button]::new()
$closeButton.Content = "x"
$closeButton.Width = 22
$closeButton.Height = 20
$closeButton.FontFamily = "Segoe UI"
$closeButton.FontWeight = "Bold"
$closeButton.Foreground = New-Brush "#DDE6EA"
$closeButton.Background = New-Brush "#243139"
$closeButton.BorderBrush = New-Brush "#3B4A52"
$closeButton.ToolTip = $script:L.close
[System.Windows.Controls.Grid]::SetColumn($closeButton, 2)

$header.Children.Add($title) | Out-Null
$header.Children.Add($script:StatusText) | Out-Null
$header.Children.Add($closeButton) | Out-Null
$layout.Children.Add($header) | Out-Null

$script:AccountText = New-Text $script:L.connecting 9.5 "#91A0A6"
$script:AccountText.Margin = "0,2,0,0"
$layout.Children.Add($script:AccountText) | Out-Null

$meterGrid = [System.Windows.Controls.Grid]::new()
$meterGrid.Margin = "0,7,0,0"
$meterGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null
$meterGap = [System.Windows.Controls.ColumnDefinition]::new()
$meterGap.Width = "10"
$meterGrid.ColumnDefinitions.Add($meterGap) | Out-Null
$meterGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new()) | Out-Null

$script:PrimaryMeter = New-Meter $script:L.primary
$script:SecondaryMeter = New-Meter $script:L.secondary
[System.Windows.Controls.Grid]::SetColumn($script:SecondaryMeter.Panel, 2)
$meterGrid.Children.Add($script:PrimaryMeter.Panel) | Out-Null
$meterGrid.Children.Add($script:SecondaryMeter.Panel) | Out-Null
$layout.Children.Add($meterGrid) | Out-Null

$script:ContextMeter = New-Meter $script:L.context
$script:ContextMeter.Panel.Margin = "0,7,0,0"
$layout.Children.Add($script:ContextMeter.Panel) | Out-Null

$grid = [System.Windows.Controls.Grid]::new()
$grid.Margin = "0,8,0,0"
$todayCol = [System.Windows.Controls.ColumnDefinition]::new()
$todayCol.Width = [System.Windows.GridLength]::new(0.82, [System.Windows.GridUnitType]::Star)
$lifetimeCol = [System.Windows.Controls.ColumnDefinition]::new()
$lifetimeCol.Width = [System.Windows.GridLength]::new(1.18, [System.Windows.GridUnitType]::Star)
$grid.ColumnDefinitions.Add($todayCol) | Out-Null
$grid.ColumnDefinitions.Add($lifetimeCol) | Out-Null
$grid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()) | Out-Null
$grid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new()) | Out-Null

$todayLabel = New-Text $script:L.today 10 "#91A0A6"
$script:TodayValue = New-Text $script:L.noData 12.5 "#F1F7F6" "Bold"
$lifetimeLabel = New-Text $script:L.lifetime 10 "#91A0A6"
$script:LifetimeValue = New-Text $script:L.noData 12.5 "#F1F7F6" "Bold"

$todayPanel = [System.Windows.Controls.StackPanel]::new()
$lifetimePanel = [System.Windows.Controls.StackPanel]::new()
$lifetimePanel.Margin = "14,0,0,0"
$todayPanel.Children.Add($todayLabel) | Out-Null
$todayPanel.Children.Add($script:TodayValue) | Out-Null
$lifetimePanel.Children.Add($lifetimeLabel) | Out-Null
$lifetimePanel.Children.Add($script:LifetimeValue) | Out-Null
[System.Windows.Controls.Grid]::SetColumn($lifetimePanel, 1)
$grid.Children.Add($todayPanel) | Out-Null
$grid.Children.Add($lifetimePanel) | Out-Null
$layout.Children.Add($grid) | Out-Null

$script:FooterText = New-Text ($script:L.source + ": app-server") 10 "#718087"
$script:FooterText.Margin = "0,6,0,0"
$layout.Children.Add($script:FooterText) | Out-Null

$window.Content = $outer

$outer.Add_MouseLeftButtonDown({
  if ($_.ButtonState -eq [System.Windows.Input.MouseButtonState]::Pressed) {
    try { $window.DragMove() } catch {}
    Save-HudSettings
  }
})

$closeButton.Add_Click({ $window.Close() })

function Update-Hud {
  try {
    if (-not (Test-Path -LiteralPath $StatusPath)) {
      $script:StatusText.Text = $script:L.connecting
      return
    }

    $statusJson = [System.IO.File]::ReadAllText($StatusPath, [System.Text.Encoding]::UTF8)
    $status = $statusJson | ConvertFrom-Json
    $script:StatusText.Text = if ($status.connected) { $script:L.connected + " " + $script:Sep + " " + $script:L.real } else { $script:L.disconnected }

    $email = Get-PropValue (Get-PropValue $status.account "account") "email"
    $plan = Get-PropValue (Get-PropValue $status.account "account") "planType"
    $planText = if ($plan) { $plan } else { $script:L.noData }
    $script:AccountText.Text = ("{0}: {1} {4} {2}: {3}" -f $script:L.account, (Shorten $email 30), $script:L.plan, $planText, $script:Sep)

    $limits = $status.rateLimits
    $byId = Get-PropValue $limits "rateLimitsByLimitId"
    $main = Get-PropValue $byId "codex"
    if ($null -eq $main) { $main = Get-PropValue $limits "rateLimits" }

    Set-MeterValue $script:PrimaryMeter ($script:L.quota + " " + $script:Sep + " " + $script:L.primary) (Get-PropValue $main "primary")
    Set-MeterValue $script:SecondaryMeter ($script:L.quota + " " + $script:Sep + " " + $script:L.secondary) (Get-PropValue $main "secondary")

    $latest = Get-PropValue $status.tokenUsage "latestDailyBucket"
    $summary = Get-PropValue $status.tokenUsage "summary"
    $todayTokens = Get-PropValue $latest "tokens"
    $lifetimeTokens = Get-PropValue $summary "lifetimeTokens"
    $script:TodayValue.Text = Format-Number $todayTokens
    $script:LifetimeValue.Text = Format-Number $lifetimeTokens

    $threadsState = Get-PropValue $status "threads"
    $selected = Get-PropValue $threadsState "selected"
    if ($null -eq $selected) {
      $recentData = Get-PropValue (Get-PropValue $threadsState "recent") "data"
      if ($recentData -and $recentData.Count -gt 0) { $selected = $recentData[0] }
    }
    $threadName = Get-PropValue $selected "name"
    if (-not $threadName) { $threadName = Get-PropValue $selected "preview" }
    $threadText = Shorten $threadName 24

    $ttu = Get-PropValue $status.threadTokenUsage "tokenUsage"
    $total = Get-PropValue (Get-PropValue $ttu "total") "totalTokens"
    $last = Get-PropValue (Get-PropValue $ttu "last") "totalTokens"
    $ctx = Get-PropValue $ttu "modelContextWindow"
    if ($last -and $ctx) {
      $ctxUsed = [Math]::Min(100, ([double]$last / [double]$ctx) * 100)
      $script:ContextMeter.Bar.Value = $ctxUsed
      $script:ContextMeter.Value.Text = ("{0:N0}% {1}" -f $ctxUsed, $script:L.used)
      $script:ContextMeter.Hint.Text = ("{0}: {1} {4} {2}/{3}" -f $script:L.recentThread, $threadText, (Format-Number $last), (Format-Number $ctx), $script:Sep)
      $script:ContextMeter.Hint.ToolTip = ("{0}: {1}`n{2} / {3} token`n{4}: {5}" -f $script:L.recentThread, $threadName, (Format-Number $last), (Format-Number $ctx), $script:L.lifetime, (Format-Number $total))
    } else {
      $script:ContextMeter.Value.Text = $script:L.noData
      $script:ContextMeter.Bar.Value = 0
      $script:ContextMeter.Hint.Text = ("{0}: {1} {2} {3}" -f $script:L.recentThread, $threadText, $script:Sep, $script:L.noThreadToken)
    }

    $updated = Get-PropValue $status "updatedAt"
    $script:FooterText.Text = ("{0}: {1} {2} app-server" -f $script:L.updated, (Format-LocalDateTimeShort $updated), $script:Sep)
    $script:FooterText.ToolTip = ("{0}: {1}" -f $script:L.updated, (Format-LocalDateTime $updated))
  } catch {
    $script:StatusText.Text = $script:L.error
    $script:FooterText.Text = ($script:L.error + ": " + (Shorten $_.Exception.Message 80))
  }
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-Hud })
$timer.Start()

$window.Add_SourceInitialized({ Update-Hud })
$window.Add_Closed({
  Save-HudSettings
  try {
    if ($script:BackendProcess -and -not $script:BackendProcess.HasExited) {
      $script:BackendProcess.Kill()
    }
  } catch {}
  try {
    if ($script:SingleInstanceMutex) {
      $script:SingleInstanceMutex.ReleaseMutex()
      $script:SingleInstanceMutex.Dispose()
    }
  } catch {}
})

$app = [System.Windows.Application]::new()
[void]$app.Run($window)

