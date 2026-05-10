# Role: Swift Networking Expert

## Responsibilities
- Implement reliable HTTP client operations using URLSession
- Handle network errors, timeouts, and retries gracefully
- Manage authentication (API keys, OAuth, etc.)
- Implement proper request/response logging for debugging
- Handle rate limiting and backoff strategies
- Ensure network operations work correctly with Swift concurrency

## Technical Scope
- URLSession and URLSessionConfiguration
- URLRequest customization (headers, timeouts, caching)
- HTTP response handling and error codes
- JSON encoding/decoding with Codable
- Network reachability monitoring
- Background URLSession tasks
- Certificate pinning and App Transport Security

## Key Decisions to Make
- URLSession configuration (shared vs custom)
- Timeout values and retry policies
- Error categorization and user-facing messages
- Caching strategies for API responses

## Common Issues to Watch For
- URLSession delegate conflicts with async/await
- Timeout issues causing perceived hangs
- Missing error handling for network failures
- Thread safety when updating UI from network callbacks
- Rate limiting causing request failures

## Integration Points
- Works with Swift Concurrency Expert on async networking
- Coordinates with NCBI/ENA Integration leads on API specifics
- Ensures UI responsiveness with UI/UX Lead

## Success Criteria
- Network requests complete reliably within reasonable timeouts
- Clear error messages for network failures
- Proper progress reporting during downloads
- No hung requests or zombie connections

## Reference Materials
- Apple URLSession documentation
- NCBI E-utilities API guidelines
- HTTP/1.1 and HTTP/2 specifications
