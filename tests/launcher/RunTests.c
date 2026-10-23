/*
 * Launcher for tests\Run-All.ps1. Build on Windows with MinGW or Visual Studio, or cross-compile:
 *   x86_64-w64-mingw32-gcc -O2 -static -o a.exe RunTests.c
 * Put a.exe in the repository root (next to src\ and tests\) and double-click it.
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    char exe[MAX_PATH], dir[MAX_PATH], cmd[2 * MAX_PATH + 128];
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    strcpy(dir, exe);
    char *slash = strrchr(dir, '\\');
    if (slash) slash[1] = '\0';

    snprintf(cmd, sizeof cmd,
             "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%stests\\Run-All.ps1\"", dir);

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "Could not start PowerShell (error %lu).\n", GetLastError());
        system("pause");
        return 2;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    printf("\nTests finished with exit code %lu.\n", code);
    system("pause");
    return (int)code;
}
