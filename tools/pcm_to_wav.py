#!/usr/bin/env python3
import argparse
import wave


def main():
    parser = argparse.ArgumentParser(description="Wrap raw signed 16-bit stereo PCM as WAV")
    parser.add_argument("--pcm", default="build/render/out.pcm")
    parser.add_argument("--wav", default="build/render/out.wav")
    parser.add_argument("--sample-rate", type=int, default=48000)
    args = parser.parse_args()

    with open(args.pcm, "rb") as f:
        pcm = f.read()
    with wave.open(args.wav, "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(args.sample_rate)
        wav.writeframes(pcm)
    print(f"wrote {args.wav}")


if __name__ == "__main__":
    main()
