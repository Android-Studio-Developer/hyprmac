/* Swift-friendly wrappers for Lua C API macros (Swift cannot import function-like macros). */
#ifndef HM_LUA_H
#define HM_LUA_H
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* Loads and runs `code`; leaves one result (or the error message) on the stack. */
static inline int hm_dostring(lua_State *L, const char *code, const char *chunkname) {
    int r = luaL_loadbufferx(L, code, strlen(code), chunkname, "t");
    if (r == LUA_OK) r = lua_pcall(L, 0, 1, 0);
    return r;
}
static inline const char *hm_tostring(lua_State *L, int idx) { return lua_tolstring(L, idx, NULL); }
static inline void hm_pop(lua_State *L, int n) { lua_settop(L, -(n)-1); }
static inline void hm_register(lua_State *L, const char *name, lua_CFunction f) {
    lua_pushcclosure(L, f, 0);
    lua_setglobal(L, name);
}
#endif
