use std::{env, fs, process};

use axiomraster_codec_api::{CodecPlugin, DecodeRequest, FrameSelection, MetadataPolicy};
use axiomraster_codec_jpeg::{DecodeBackend, JpegCodec};
use axiomraster_core::{DecodeLimits, PixelFormat};
use axiomraster_runtime::SliceSource;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        return Err("usage: imagecraft-axiom-packed-probe INPUT.jpg OUTPUT.rgba".into());
    }
    let bytes = fs::read(&args[1]).map_err(|error| format!("read input: {error}"))?;
    let limits = DecodeLimits::DEFAULT_NETWORK;
    let codec = JpegCodec;
    let backend = codec
        .select_decode_backend(&bytes, PixelFormat::RGBA8, limits)
        .map_err(|error| format!("select backend: {:?}: {}", error.kind, error.message))?;
    if backend != DecodeBackend::NativeScalar {
        return Err(format!("expected NativeScalar, got {backend:?}"));
    }

    let mut source = SliceSource::new(&bytes);
    let asset = codec
        .decode(
            &mut source,
            DecodeRequest {
                output_format: PixelFormat::RGBA8,
                limits,
                metadata: MetadataPolicy::Discard,
                frames: FrameSelection::Primary,
            },
        )
        .map_err(|error| format!("decode: {:?}: {}", error.kind, error.message))?;
    if asset.frames.len() != 1 {
        return Err(format!("expected one frame, got {}", asset.frames.len()));
    }
    let frame = &asset.frames[0];
    let dimensions = frame.layout.dimensions();
    let expected_stride = u64::from(dimensions.width())
        .checked_mul(4)
        .ok_or_else(|| "stride overflow".to_string())?;
    if frame.layout.format() != PixelFormat::RGBA8 || frame.layout.stride_bytes() != expected_stride
    {
        return Err("Axiom output is not tight RGBA8".into());
    }
    if frame.pixels.len() as u64 != frame.layout.byte_len() {
        return Err("Axiom output byte count disagrees with layout".into());
    }
    let all_alpha_opaque = frame.pixels.chunks_exact(4).all(|pixel| pixel[3] == 255);
    if !all_alpha_opaque {
        return Err("JPEG RGBA8 output published non-opaque alpha".into());
    }
    fs::write(&args[2], &frame.pixels).map_err(|error| format!("write output: {error}"))?;
    println!(
        "{{\"schemaVersion\":1,\"implementation\":\"AxiomRasterCodecJPEG.NativeScalar\",\"backend\":\"NativeScalar\",\"pixelContract\":\"RGBA8-opaque-top-to-bottom-tight\",\"width\":{},\"height\":{},\"bytesPerRow\":{},\"byteCount\":{},\"allAlphaOpaque\":true}}",
        dimensions.width(),
        dimensions.height(),
        frame.layout.stride_bytes(),
        frame.pixels.len()
    );
    Ok(())
}
