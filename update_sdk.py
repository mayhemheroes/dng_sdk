#!/usr/bin/env python3

import os
import re
import sys
import shutil
import subprocess
import urllib.request
import zipfile
import tempfile

ADOBE_URL = "https://helpx.adobe.com/camera-raw/digital-negative.html"
VERSIONS_DIR = "versions"
SOURCE_DIR = "source"

def get_latest_version_info():
    print(f"Checking {ADOBE_URL} for updates...")
    with urllib.request.urlopen(ADOBE_URL) as response:
        html = response.read().decode('utf-8')

    # Look for the download link and version string
    # Example: <a href="https://www.adobe.com/go/dng_sdk" ...>Download the Adobe DNG SDK</a> (1.7.1 Build 2502, March 10, 2026)
    match = re.search(r'href="(https://www\.adobe\.com/go/dng_sdk)".*?Download the Adobe DNG SDK</a>\s*\((.*?),', html, re.DOTALL)
    if not match:
        print("Could not find download link or version info on Adobe page.")
        return None, None

    go_url = match.group(1)
    version_str = match.group(2) # e.g. "1.7.1 Build 2502"

    # Resolve the redirect to get the actual ZIP URL
    req = urllib.request.Request(go_url, method='HEAD')
    with urllib.request.urlopen(req) as response:
        zip_url = response.geturl()

    return zip_url, version_str

def get_current_version_info():
    zips = [f for f in os.listdir(VERSIONS_DIR) if f.endswith(".zip")]
    if not zips:
        return None, None
    # Sort by filename, assuming they follow a consistent naming scheme
    zips.sort()
    latest_zip = zips[-1]

    # Extract version from filename: dng_sdk_1_7_1_2471_20260129.zip
    match = re.search(r'dng_sdk_(\d+)_(\d+)_(\d+)_(\d+)_', latest_zip)
    if match:
        version = f"{match.group(1)}.{match.group(2)}.{match.group(3)} Build {match.group(4)}"
        return version, os.path.join(VERSIONS_DIR, latest_zip)
    return None, os.path.join(VERSIONS_DIR, latest_zip)

def download_file(url, dest):
    print(f"Downloading {url} to {dest}...")
    urllib.request.urlretrieve(url, dest)

def extract_source(zip_path, extract_to):
    print(f"Extracting source from {zip_path} to {extract_to}...")
    with zipfile.ZipFile(zip_path, 'r') as zip_ref:
        for member in zip_ref.namelist():
            # Look for files in dng_sdk_*/dng_sdk/source/
            if "/dng_sdk/source/" in member:
                filename = os.path.basename(member)
                if not filename:
                    continue

                # We want to extract it such that it's flat in extract_to
                source_path = member
                target_path = os.path.join(extract_to, filename)

                with zip_ref.open(source_path) as source, open(target_path, 'wb') as target:
                    shutil.copyfileobj(source, target)

def main():
    if not os.path.exists(VERSIONS_DIR):
        os.makedirs(VERSIONS_DIR)

    zip_url, latest_version = get_latest_version_info()
    if not zip_url:
        sys.exit(1)

    curr_version, curr_zip_path = get_current_version_info()

    print(f"Current version: {curr_version}")
    print(f"Latest version:  {latest_version}")

    if curr_version == latest_version:
        print("Already up to date.")
        # return # For testing, I'll continue if I want to force it, but let's follow the request.
        # sys.exit(0)

    # Determine new zip filename from URL
    new_zip_name = os.path.basename(zip_url)
    new_zip_path = os.path.join(VERSIONS_DIR, new_zip_name)

    if not os.path.exists(new_zip_path):
        download_file(zip_url, new_zip_path)
    else:
        print(f"{new_zip_path} already exists.")

    # Create diff and apply
    with tempfile.TemporaryDirectory() as tmpdir:
        old_src = os.path.join(tmpdir, "old")
        new_src = os.path.join(tmpdir, "new")
        os.makedirs(old_src)
        os.makedirs(new_src)

        extract_source(curr_zip_path, old_src)
        extract_source(new_zip_path, new_src)

        patch_file = os.path.join(tmpdir, "update.patch")
        print(f"Creating patch...")
        # Use diff -Naur to handle new/deleted files
        result = subprocess.run(["diff", "-Naur", "old", "new"], cwd=tmpdir, capture_output=True, text=True)

        with open(patch_file, "w") as f:
            f.write(result.stdout)

        if not result.stdout:
            print("No differences found between upstream versions.")
            sys.exit(0)

        print(f"Applying patch to {SOURCE_DIR}...")
        # Apply patch with -p1 because the diff was created in tmpdir with old/ and new/
        patch_cmd = ["patch", "-p1", "-i", patch_file]
        try:
            subprocess.run(patch_cmd, cwd=SOURCE_DIR, check=True)
        except subprocess.CalledProcessError:
            print("Patch failed to apply cleanly. Manual resolution may be required.")
            sys.exit(1)

    update_readme(zip_url, latest_version)
    print("Update complete.")

def update_readme(zip_url, version_str):
    readme_path = "README.version"
    if not os.path.exists(readme_path):
        return

    # Extract version without "Build" for README if needed, or just use the full string
    # Adobe often uses X.Y.Z format in README.version
    version_match = re.search(r'(\d+\.\d+\.\d+)', version_str)
    version = version_match.group(1) if version_match else version_str

    with open(readme_path, "r") as f:
        content = f.read()

    content = re.sub(r'URL: .*', f'URL: {zip_url}', content)
    content = re.sub(r'Version: .*', f'Version: {version}', content)

    with open(readme_path, "w") as f:
        f.write(content)
    print(f"Updated {readme_path}")

if __name__ == "__main__":
    main()
