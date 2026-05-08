"""Dispatches a resource URI to the appropriate Phaser by media_type.

Mirror of Esr.Resource.Media.PhaserRegistry per spec §3.4."""
from esr.uri import parse_resource

from esr.resource.media import resolve
from esr.resource.media.image_phaser import ImagePhaser
from esr.resource.media.file_phaser import FilePhaser

_PHASERS = {
    "image": ImagePhaser,
    "file": FilePhaser,
    # audio added in future PR
}


def registered_media_types():
    return list(_PHASERS.keys())


def transform(uri: str, target: str):
    """Resolve uri, look up Phaser by media_type, dispatch to transform.

    Raises ValueError('no_phaser_for_media_type: <mt>') if no Phaser
    registered. Other errors propagated from resolve (EsrResourceError)
    or Phaser (ValueError)."""
    parsed = parse_resource(uri)
    path = resolve(uri)
    phaser = _PHASERS.get(parsed["media_type"])
    if phaser is None:
        raise ValueError(f"no_phaser_for_media_type: {parsed['media_type']}")
    return phaser.transform(("path", str(path)), target)
