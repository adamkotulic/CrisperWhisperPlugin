# Third-party software and models

This repository contains integration code. It does not contain or redistribute
CrisperWhisper model weights.

## TypeWhisperPluginSDK

The plugin links against
[TypeWhisperPluginSDK](https://github.com/TypeWhisper/TypeWhisperPluginSDK),
which is licensed under GNU GPL version 3. The plugin source is consequently
distributed under GPL-3.0.

## CrisperWhisper

The isolated runtime installs
[`crisperwhisper`](https://github.com/nyrahealth/CrisperWhisper) 2.0.1 at
installation time. Its source code is MIT-licensed and includes the upstream
notices documented in its repository.

## Model weights

The installer can download model weights directly from
[`nyralabs` on Hugging Face](https://huggingface.co/nyralabs). The standard
CrisperWhisper 2.0 weights are offered under Nyra's non-commercial research
terms. Commercial use requires a separate commercial license from Nyra.

Users are responsible for reviewing and complying with the terms presented by
the selected model repository before downloading or using its weights.
