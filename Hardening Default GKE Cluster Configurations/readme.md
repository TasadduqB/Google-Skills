# GKE Hardening Lab - Automation Script

This guide explains how to run the automated solution for the **Hardening Default GKE Cluster Configurations** lab using Google Cloud Shell.

## How to Run

### 1. Open Cloud Shell
* Log in to the Google Cloud Console.
* Click the **Activate Cloud Shell** icon ( `>_` ) in the top right toolbar.

### 2. Check Your Zone
* Look at your lab instructions to see which **Zone** is assigned to you (e.g., `us-central1-c`, `us-west1-b`, etc.).
* **Note:** The script defaults to `us-central1-c`.

### 3. Copy, Edit, and Run
1.  Copy the entire script block provided to you.
2.  If you need to change the **Zone**:
    * Paste the script into a text editor (like Notepad).
    * Find the line: `export MY_ZONE=us-central1-c`
    * Change it to your required zone.
    * Copy the updated script.
3.  Paste the code into the **Cloud Shell terminal**.
4.  Hit **Enter**.

The script will automatically create the file, set permissions, and execute all lab tasks.
