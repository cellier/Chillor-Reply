# Third-party components

This source repository does not contain model weights or the Ollama runtime binaries.

- **Ollama 0.33.3** is downloaded from its official GitHub release by `build.sh`. Its upstream project is MIT-licensed: https://github.com/ollama/ollama/blob/v0.33.3/LICENSE . Keep all license/notice files shipped in the extracted runtime when distributing a built app, including notices for bundled dependencies.
- **Qwen 3.8 27B** is downloaded separately through Ollama. Consult the model card and the license accompanying the downloaded model: https://huggingface.co/Qwen/Qwen3.8-27B and https://ollama.com/library/qwen3.8:27b . A project source license does not relicense model weights.
- **Apple frameworks and SDKs** are provided by the system/Xcode under their applicable terms. They are not included as source in this repository.

The application icon and localization resources are project assets. Brand names do not imply endorsement by upstream vendors.
