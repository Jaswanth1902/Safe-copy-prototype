"""Package initializer for the testable server package.

This file re-exports the contents of the module defined in `server.py`
so that tests which do `import server` can access `app`,
`SERVER_X25519_PUBLIC_BYTES`, and other symbols directly.
"""
from .server import *  # noqa: F401,F403
