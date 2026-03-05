-- Shared constants for sap
local M = {}

-- Buffer naming
M.BUFFER_SCHEME = "sap:///"

-- Entry ID prefix format (used with string.format)
-- Format: ///{id}:
M.ID_FORMAT = "///%d:"

-- Lua pattern to parse ID from line
-- Captures: id, rest_of_line
M.ID_PATTERN = "^///(%d+):(.*)$"

-- Vim syntax pattern for concealing ID prefix
M.ID_SYNTAX_PATTERN = [[^///\d\+:]]

return M
