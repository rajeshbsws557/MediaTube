@rem Gradle wrapper batch script for Windows
@rem This downloads Gradle if not present and runs it

@echo off
setlocal

set DIRNAME=%~dp0
if "%DIRNAME%"=="" set DIRNAME=.

@rem Check for Java
java -version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Java not found. Please install JDK 17 or higher.
    exit /b 1
)

@rem Download Gradle if wrapper not available
if not exist "%DIRNAME%gradle\wrapper\gradle-wrapper.jar" (
    echo Downloading Gradle wrapper...
    mkdir "%DIRNAME%gradle\wrapper" 2>nul
    powershell -Command "Invoke-WebRequest -Uri 'https://github.com/gradle/gradle/raw/v8.5.0/gradle/wrapper/gradle-wrapper.jar' -OutFile '%DIRNAME%gradle\wrapper\gradle-wrapper.jar'"
)

@rem Run Gradle
java -classpath "%DIRNAME%gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain %*
