$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$appRoot = Split-Path -Parent $PSScriptRoot
$brandRoot = Join-Path $appRoot 'assets/brand'
$sourceRoot = Join-Path $brandRoot 'sources'
$mainSourcePath = Join-Path $sourceRoot 'miyin-app-icon-source.png'
$foregroundSourcePath = Join-Path $sourceRoot 'miyin-adaptive-foreground-source.png'
$monochromeSourcePath = Join-Path $sourceRoot 'miyin-adaptive-monochrome-source.png'
$backgroundSourcePath = Join-Path $sourceRoot 'miyin-adaptive-background-source.png'

foreach ($sourcePath in @($mainSourcePath, $foregroundSourcePath, $monochromeSourcePath, $backgroundSourcePath)) {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required icon source is missing: $sourcePath"
    }
}

function Save-ScaledImage {
    param(
        [Parameter(Mandatory)] [System.Drawing.Bitmap] $Source,
        [Parameter(Mandatory)] [System.Drawing.Rectangle] $SourceRect,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [Parameter(Mandatory)] [int] $CanvasSize,
        [double] $MaxArtworkFraction = 1.0,
        [switch] $OpaqueCanvas
    )

    $destinationDirectory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    $pixelFormat = if ($OpaqueCanvas) { [System.Drawing.Imaging.PixelFormat]::Format24bppRgb } else { [System.Drawing.Imaging.PixelFormat]::Format32bppArgb }
    $bitmap = [System.Drawing.Bitmap]::new($CanvasSize, $CanvasSize, $pixelFormat)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $canvasColor = if ($OpaqueCanvas) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Transparent }
        $graphics.Clear($canvasColor)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

        $scale = [Math]::Min(($CanvasSize * $MaxArtworkFraction) / $SourceRect.Width, ($CanvasSize * $MaxArtworkFraction) / $SourceRect.Height)
        $width = [Math]::Max(1, [int][Math]::Round($SourceRect.Width * $scale))
        $height = [Math]::Max(1, [int][Math]::Round($SourceRect.Height * $scale))
        $destinationRect = [System.Drawing.Rectangle]::new([int](($CanvasSize - $width) / 2), [int](($CanvasSize - $height) / 2), $width, $height)
        $graphics.DrawImage($Source, $destinationRect, $SourceRect, [System.Drawing.GraphicsUnit]::Pixel)
        $bitmap.Save($DestinationPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-AlphaBounds {
    param([Parameter(Mandatory)] [System.Drawing.Bitmap] $Bitmap)
    $minX = $Bitmap.Width
    $minY = $Bitmap.Height
    $maxX = -1
    $maxY = -1
    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            if ($Bitmap.GetPixel($x, $y).A -gt 16) {
                $minX = [Math]::Min($minX, $x)
                $minY = [Math]::Min($minY, $y)
                $maxX = [Math]::Max($maxX, $x)
                $maxY = [Math]::Max($maxY, $y)
            }
        }
    }
    if ($maxX -lt $minX -or $maxY -lt $minY) {
        throw 'The adaptive icon artwork has no visible pixels.'
    }
    return [System.Drawing.Rectangle]::new($minX, $minY, $maxX - $minX + 1, $maxY - $minY + 1)
}

$mainSource = [System.Drawing.Bitmap]::FromFile($mainSourcePath)
try {
    $mainRect = [System.Drawing.Rectangle]::new(0, 0, $mainSource.Width, $mainSource.Height)
    $androidIcons = @{
        'mipmap-mdpi/ic_launcher.png' = 48
        'mipmap-hdpi/ic_launcher.png' = 72
        'mipmap-xhdpi/ic_launcher.png' = 96
        'mipmap-xxhdpi/ic_launcher.png' = 144
        'mipmap-xxxhdpi/ic_launcher.png' = 192
    }
    foreach ($entry in $androidIcons.GetEnumerator()) {
        Save-ScaledImage -Source $mainSource -SourceRect $mainRect -DestinationPath (Join-Path $appRoot "android/app/src/main/res/$($entry.Key)") -CanvasSize $entry.Value -OpaqueCanvas
    }

    $iosContentsPath = Join-Path $appRoot 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json'
    $iosContents = Get-Content -LiteralPath $iosContentsPath -Raw | ConvertFrom-Json
    $iosIconDirectory = Join-Path $appRoot 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    $iosIconDirectoryFull = [System.IO.Path]::GetFullPath($iosIconDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    foreach ($icon in $iosContents.images) {
        $filename = [string]$icon.filename
        if ([string]::IsNullOrWhiteSpace($filename) -or [System.IO.Path]::GetFileName($filename) -cne $filename -or $filename -notmatch '^[A-Za-z0-9._@-]+\.png$') {
            throw "Unsafe iOS icon filename in Contents.json: $filename"
        }
        $baseSize = [double]::Parse(($icon.size -split 'x')[0], [Globalization.CultureInfo]::InvariantCulture)
        $scale = [double]::Parse($icon.scale.TrimEnd('x'), [Globalization.CultureInfo]::InvariantCulture)
        $pixelSize = [int][Math]::Round($baseSize * $scale)
        $destinationPath = [System.IO.Path]::GetFullPath((Join-Path $iosIconDirectoryFull $filename))
        $allowedPrefix = $iosIconDirectoryFull + [System.IO.Path]::DirectorySeparatorChar
        if (-not $destinationPath.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "iOS icon output escaped the app icon directory: $destinationPath"
        }
        Save-ScaledImage -Source $mainSource -SourceRect $mainRect -DestinationPath $destinationPath -CanvasSize $pixelSize -OpaqueCanvas
    }
}
finally {
    $mainSource.Dispose()
}

$foregroundSource = [System.Drawing.Bitmap]::FromFile($foregroundSourcePath)
$monochromeSource = [System.Drawing.Bitmap]::FromFile($monochromeSourcePath)
$backgroundSource = [System.Drawing.Bitmap]::FromFile($backgroundSourcePath)
try {
    $drawableRoot = Join-Path $appRoot 'android/app/src/main/res/drawable-nodpi'
    $foregroundBounds = Get-AlphaBounds -Bitmap $foregroundSource
    $monochromeBounds = Get-AlphaBounds -Bitmap $monochromeSource
    Save-ScaledImage -Source $foregroundSource -SourceRect $foregroundBounds -DestinationPath (Join-Path $drawableRoot 'ic_launcher_foreground.png') -CanvasSize 432 -MaxArtworkFraction .60
    Save-ScaledImage -Source $monochromeSource -SourceRect $monochromeBounds -DestinationPath (Join-Path $drawableRoot 'ic_launcher_monochrome.png') -CanvasSize 432 -MaxArtworkFraction .60

    $cropMargin = [int][Math]::Round([Math]::Min($backgroundSource.Width, $backgroundSource.Height) * .10)
    $cropSize = [Math]::Min($backgroundSource.Width, $backgroundSource.Height) - (2 * $cropMargin)
    $backgroundBounds = [System.Drawing.Rectangle]::new([int](($backgroundSource.Width - $cropSize) / 2), [int](($backgroundSource.Height - $cropSize) / 2), $cropSize, $cropSize)
    Save-ScaledImage -Source $backgroundSource -SourceRect $backgroundBounds -DestinationPath (Join-Path $drawableRoot 'ic_launcher_background.png') -CanvasSize 432 -OpaqueCanvas
}
finally {
    $foregroundSource.Dispose()
    $monochromeSource.Dispose()
    $backgroundSource.Dispose()
}

Copy-Item -LiteralPath $mainSourcePath -Destination (Join-Path $brandRoot 'miyin-logo-selected.png') -Force
Write-Output 'Generated Android density/adaptive icons and all iOS app icon sizes.'
