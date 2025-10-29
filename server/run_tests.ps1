#!/usr/bin/env pwsh
Write-Host "Installing requirements and running pytest..."
python -m pip install -r requirements.txt
python -m pytest -q
