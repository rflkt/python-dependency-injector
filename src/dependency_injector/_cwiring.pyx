"""Wiring optimizations module."""

import asyncio
import collections.abc
import functools
import inspect
import types

from . import providers
from .wiring import _Marker, PatchedCallable

from .providers cimport Provider


def _get_sync_patched(fn, patched: PatchedCallable):
    @functools.wraps(fn)
    def _patched(*args, **kwargs):
        cdef object result
        cdef dict to_inject
        cdef object arg_key
        cdef Provider provider

        to_inject = kwargs.copy()
        for arg_key, provider in patched.injections.items():
            if arg_key not in kwargs or isinstance(kwargs[arg_key], _Marker):
                to_inject[arg_key] = provider()

        try:
            return fn(*args, **to_inject)
        finally:
            if patched.closing:
                for arg_key, provider in patched.closing.items():
                    if arg_key in kwargs and not isinstance(kwargs[arg_key], _Marker):
                        continue
                    if not isinstance(provider, providers.Resource):
                        continue
                    provider.shutdown()

    return _patched


async def _async_inject(object fn, tuple args, dict kwargs, dict injections, dict closings):
    cdef object result
    cdef dict to_inject
    cdef list to_inject_await = []
    cdef list to_close_await = []
    cdef object arg_key
    cdef Provider provider

    to_inject = kwargs.copy()
    for arg_key, provider in injections.items():
        if arg_key not in kwargs or isinstance(kwargs[arg_key], _Marker):
            provide = provider()
            if provider.is_async_mode_enabled():
                to_inject_await.append((arg_key, provide))
            elif _is_awaitable(provide):
                to_inject_await.append((arg_key, provide))
            else:
                to_inject[arg_key] = provide

    if to_inject_await:
        async_to_inject = await asyncio.gather(*(provide for _, provide in to_inject_await))
        for provide, (injection, _) in zip(async_to_inject, to_inject_await):
            to_inject[injection] = provide
    try:
        return await fn(*args, **to_inject)
    finally:
        if closings:
            for arg_key, provider in closings.items():
                if arg_key in kwargs and isinstance(kwargs[arg_key], _Marker):
                    continue
                if not isinstance(provider, providers.Resource):
                    continue
                shutdown = provider.shutdown()
                if _is_awaitable(shutdown):
                    to_close_await.append(shutdown)

            await asyncio.gather(*to_close_await)



cdef bint _is_awaitable(object instance):
    """Return true if object can be passed to an ``await`` expression."""
    return (isinstance(instance, types.CoroutineType) or
            isinstance(instance, types.GeneratorType) and
            bool(instance.gi_code.co_flags & inspect.CO_ITERABLE_COROUTINE) or
            isinstance(instance, collections.abc.Awaitable))
