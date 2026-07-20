-- Feature gating: a feature declares the mapped symbols it needs; if any are missing
-- (still nil in mapping.lua), the feature disables itself instead of crashing.
local M = {}

-- keys: list of "section.key" strings. Returns ok(bool), missing(list).
function M.check(map, keys)
  local missing = {}
  for _, dotted in ipairs(keys) do
    local section, key = dotted:match("^([%w_]+)%.([%w_]+)$")
    local present = section and key and map[section] and map[section][key] ~= nil
    if not present then missing[#missing + 1] = dotted end
  end
  return #missing == 0, missing
end

-- Convenience: require keys for a named feature; logs and returns false if any missing.
function M.require(log, map, feature, keys)
  local ok, missing = M.check(map, keys)
  if not ok then
    log.warn(string.format("%s: DISABLED (unmapped: %s)", feature, table.concat(missing, ", ")))
  end
  return ok
end

return M
