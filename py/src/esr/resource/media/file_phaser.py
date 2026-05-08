"""Generic file Phaser -- mirror of Esr.Resource.Media.FilePhaser."""
import pathlib


class FilePhaser:
    media_type = "file"
    input_formats = ("path",)
    output_formats = ("path", "bytes", "inline_text")
    streaming = False

    INLINE_TEXT_MAX = 100_000

    @classmethod
    def transform(cls, input_, target):
        kind, value = input_
        if kind != "path":
            raise ValueError(f"unsupported_input_format: {kind}")
        p = pathlib.Path(value)
        if target == "path":
            return p
        if target == "bytes":
            return p.read_bytes()
        if target == "inline_text":
            if p.stat().st_size > cls.INLINE_TEXT_MAX:
                raise ValueError("too_large_for_inline")
            return p.read_text()
        raise ValueError(f"unsupported_target: {target}")
