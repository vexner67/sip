"""Sip: язык программирования, который бережёт токены ИИ. Транслируется в Python."""

from .compiler import Compiled, compile_file, compile_source, execute
from .errors import SipError

__version__ = "0.1.0"
__all__ = ["Compiled", "SipError", "compile_file", "compile_source", "execute"]
