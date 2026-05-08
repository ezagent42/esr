"""Image content Phaser -- mirror of Esr.Resource.Media.ImagePhaser."""
import base64
import pathlib

_MIME = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "heic": "image/heic",
}


class ImagePhaser:
    media_type = "image"
    input_formats = ("path",)
    output_formats = ("path", "bytes", "base64_data_url")
    streaming = False

    @staticmethod
    def transform(input_, target):
        kind, value = input_
        if kind != "path":
            raise ValueError(f"unsupported_input_format: {kind}")
        p = pathlib.Path(value)

        if target == "path":
            return p
        if target == "bytes":
            return p.read_bytes()
        if target == "base64_data_url":
            ext = p.suffix.lstrip(".").lower()
            mime = _MIME.get(ext, "application/octet-stream")
            b64 = base64.b64encode(p.read_bytes()).decode("ascii")
            return f"data:{mime};base64,{b64}"
        raise ValueError(f"unsupported_target: {target}")
