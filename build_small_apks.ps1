flutter build apk --release --split-per-abi

Get-ChildItem -Path "build/app/outputs/flutter-apk" -Filter "*release.apk" |
    Sort-Object Name |
    Select-Object Name, @{Name = "MB"; Expression = { [math]::Round($_.Length / 1MB, 2) } }, FullName
