"""Recent explicit setup evidence, not a promise that OS authorization cannot change."""
import hashlib
import json
import math
from pathlib import Path
import re
import time
try:
    from release_profiles import read_private_json, write_private_json, ProfileError
except ModuleNotFoundError:
    from scripts.release.release_profiles import read_private_json, write_private_json, ProfileError


class ReadinessError(ValueError):
    pass


def setup_binding(selectors, tools, boot_identity):
    identities = {}
    for name, raw_path in tools.items():
        path = Path(raw_path).resolve(strict=True)
        identities[name] = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    document = dict(selectors=selectors, tools=identities, bootIdentity=boot_identity)
    return hashlib.sha256(json.dumps(document, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def write_setup_receipt(path, binding, *, now=None):
    if re.fullmatch('[0-9a-f]{64}', binding) is None: raise ReadinessError('invalid setup binding')
    write_private_json(path, dict(schemaVersion=1, binding=binding, completed=True, observedAt=time.time() if now is None else now, limitation='Recent successful setup probes; keychain relock or changed OS authorization can still require interaction.'), replace=path.exists())


def require_setup_receipt(path, binding, *, now=None, max_age=None):
    if path is None: raise ReadinessError('explicit credential setup is required before unattended credential access')
    try: value = read_private_json(path)
    except ProfileError as error: raise ReadinessError('credential setup receipt is missing or unsafe; run explicit setup') from error
    observed = value.get('observedAt')
    age = (time.time() if now is None else now) - observed if type(observed) in (int, float) else -1
    if value.get('schemaVersion') != 1 or value.get('completed') is not True or value.get('binding') != binding or not math.isfinite(age) or age < 0 or (max_age is not None and age > max_age):
        raise ReadinessError('credential setup evidence expired or tool/selector/boot identity changed; run explicit setup')
    return value


def begin_setup(path, binding, *, now=None):
    """Invalidate previous readiness before probing, so a failed refresh cannot authorize use."""
    if re.fullmatch('[0-9a-f]{64}', binding) is None: raise ReadinessError('invalid setup binding')
    write_private_json(path, dict(schemaVersion=1, binding=binding, completed=False,
        observedAt=time.time() if now is None else now), replace=path.exists())
