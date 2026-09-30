# Contributing

Build from source using the README and run the existing test suites before submitting a change. Keep capture, reply generation and user confirmation separate; never introduce automatic message sending.

Use synthetic messages and generated fixtures. Do not attach real chats, screenshots, memory databases, keys, downloaded models, sensor traces or internal links to public issues or pull requests. For gesture bugs, describe macOS version, hardware model, sensitivity, cadence and observed behavior without uploading personal recordings by default.

For behavior changes, include focused regression tests and explain their limits. Synthetic gesture tests are not a real-world accuracy benchmark. Changes to stored data need backward-compatible migration and failure-path tests. Keep English, simplified Chinese and traditional Chinese resources consistent.

Submit a pull request with the problem, resulting behavior and validation. Keep the historical bundle identifier and data paths stable unless a migration is explicitly designed.
