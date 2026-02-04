# MediaTube Server

A lightweight Java backend server for YouTube video URL extraction using [NewPipe Extractor](https://github.com/TeamNewPipe/NewPipeExtractor).

## Features

- 🎬 **YouTube Support** - Extract video streams up to 4K/2160p
- ☕ **Pure Java** - No Python or yt-dlp dependencies
- 🔄 **Auto-Update API** - Endpoint for app version checking
- 🪶 **Lightweight** - URL extraction only; downloads handled by the app

## Requirements

- **Java 17+** (JDK 17 or higher)
- **Maven** (for building)

## Quick Start

### Option 1: Using Maven

```bash
cd java-server
mvn clean package
java -jar target/mediatube-server-1.0.0.jar
```

### Option 2: Using Gradle

```bash
cd java-server
./gradlew run
```

The server runs on `http://localhost:5000` by default.

## API Endpoints

### Health Check
```http
GET /health
```
Response:
```json
{
  "status": "ok",
  "server": "MediaTube Java Server",
  "version": "2.0.0"
}
```

### Get Video Formats
```http
GET /formats?url=https://youtube.com/watch?v=VIDEO_ID
```
Returns all available streams for a YouTube video.

### App Version Check
```http
GET /api/app-version
```
Response:
```json
{
  "version": "1.0.0",
  "changelog": "Initial release",
  "downloadUrl": "https://github.com/YOUR_USERNAME/MediaTube/releases/download/v1.0.0/app-release.apk"
}
```

## Configuration

### Updating App Version
When releasing a new app version, update these values in `MediaTubeServer.java`:

```java
// Inside the /api/app-version endpoint:
String currentVersion = "1.1.0";  // New version
String changelog = "Bug fixes and performance improvements";
String downloadUrl = "https://github.com/YOUR_USERNAME/MediaTube/releases/download/v1.1.0/app-release.apk";
```

### Changing Port
Modify `PORT` constant in `MediaTubeServer.java`:
```java
private static final int PORT = 5000;
```

## Deployment

### Local Network (Recommended for testing)
1. Find your computer's local IP (e.g., `192.168.1.100`)
2. Run the server
3. Configure the app with `http://192.168.1.100:5000`

### Cloud Deployment
Deploy to any Java-supporting platform:
- **Heroku**: Add `Procfile` with `web: java -jar target/*.jar`
- **Railway**: Supports Java projects directly
- **VPS**: Run with `java -jar` and use nginx reverse proxy

## Why NewPipe Extractor?

- **Actively maintained** by the NewPipe team
- **No API key required** - Works through web scraping like a browser
- **Handles YouTube's anti-bot measures** internally
- **Pure Java** - No external dependencies like Python
- **Battle-tested** - Powers millions of NewPipe app users

## Troubleshooting

### Server not accessible from phone
- Ensure phone and computer are on the same network
- Check firewall settings (allow port 5000)
- Try using your computer's actual IP, not `localhost`

### YouTube streams not loading
- YouTube occasionally changes their frontend
- Wait for a NewPipe Extractor update
- Check the [NewPipe issues](https://github.com/TeamNewPipe/NewPipeExtractor/issues)

## License

MIT License - See [LICENSE](../LICENSE) for details.
