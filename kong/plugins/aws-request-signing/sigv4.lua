-- Performs AWSv4 Signing
-- http://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html
-- Slightly modified version of https://github.com/Kong/kong/blob/master/kong/plugins/aws-lambda/v4.lua

-- BSD License
local resty_sha256 = require "resty.sha256"
-- MIT License
local pl_string = require "pl.stringx"
-- BSD 2-Clause License
local openssl_hmac = require "resty.openssl.hmac"

local ALGORITHM = "AWS4-HMAC-SHA256"

local ngx = ngx

local function notEmpty(s)
  return s ~= nil and s ~= ''
end

local CHAR_TO_HEX = {};
for i = 0, 255 do
  local char = string.char(i)
  local hex = string.format("%02x", i)
  CHAR_TO_HEX[char] = hex
end

local function hmac(secret, data)
  return openssl_hmac.new(secret, "sha256"):final(data)
end

local function hash(str)
  local sha256 = resty_sha256:new()
  sha256:update(str)
  return sha256:final()
end

local function hex_encode(str) -- From prosody's util.hex
  return (str:gsub(".", CHAR_TO_HEX))
end

local function percent_encode(char)
  return string.format("%%%02X", string.byte(char))
end

local function canonicalise_path(path)
  local segments = {}
  for segment in path:gmatch("/([^/]*)") do
    if segment == "" or segment == "." then
      segments = segments -- do nothing and avoid lint
    elseif segment == " .. " then
      -- intentionally discards components at top level
      segments[#segments] = nil
    else
      segments[#segments+1] = ngx.unescape_uri(segment):gsub("[^%w%-%._~]",
                                                             percent_encode)
    end
  end
  local len = #segments
  if len == 0 then
    return "/"
  end
  -- If there was a slash on the end, keep it there.
  if path:sub(-1, -1) == "/" then
    len = len + 1
    segments[len] = nil
  end
  segments[0] = ""
  local segmentsString = table.concat(segments, "/", 0, len)
  return segmentsString
end

local function canonicalise_query_string(query)
  local q = {}
  for key, val in query:gmatch("([^&=]+)=?([^&]*)") do
    key = ngx.unescape_uri(key):gsub("[^%w%-%._~]", percent_encode)
    val = ngx.unescape_uri(val):gsub("[^%w%-%._~]", percent_encode)
    q[#q+1] = key .. "=" .. val
  end
  table.sort(q)
  return table.concat(q, "&")
end

local function derive_signing_key(kSecret, date, region, service)
  local kDate = hmac("AWS4" .. kSecret, date)
  local kRegion = hmac(kDate, region)
  local kService = hmac(kRegion, service)
  local kSigning = hmac(kService, "aws4_request")
  return kSigning
end

local function prepare_awsv4_request(tbl)
  local region = tbl.region
  local service = tbl.service
  local request_method = tbl.method
  local canonicalURI = tbl.canonicalURI
  local path = tbl.path
  local host = tbl.host


  if path and not canonicalURI then
    canonicalURI = canonicalise_path(path)
  elseif canonicalURI == nil or canonicalURI == "" then
    canonicalURI = "/"
  end


  local canonical_querystring = tbl.canonical_querystring
  local query = tbl.query
  if query and not canonical_querystring then
    canonical_querystring = canonicalise_query_string(query)
  end


  local req_headers = tbl.headers or {}
  local req_payload = tbl.body
  local access_key = tbl.access_key
  local signing_key = tbl.signing_key
  local secret_key
  if not signing_key then
    secret_key = tbl.secret_key
    if secret_key == nil then
      return nil, "either 'signing_key' or 'secret_key' must be provided"
    end
  end

  local tls = tbl.tls
  if tls == nil then
    tls = true
  end

  local port = tbl.port or (tls and 443 or 80)
  local timestamp = tbl.timestamp or ngx.time()
  local req_date = os.date("!%Y%m%dT%H%M%SZ", timestamp)
  local date = os.date("!%Y%m%d", timestamp)

  local host_header do -- If the "standard" port is not in use, the port should be added to the Host header
    local with_port
    if tls then
      with_port = port ~= 443
    else
      with_port = port ~= 80
    end
    if with_port then
      host_header = string.format("%s:%d", host, port)
    else
      host_header = host
    end
  end

  local lowerHeaders = {
    ["x-amz-date"] = req_date;
    host = host_header;
  }

  for k, v in pairs(req_headers) do
    k = k:lower() -- convert to lower case header name
    lowerHeaders[k] = v
  end

  -- Task 1: Create a Canonical Request For Signature Version 4
  -- http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
  local canonical_headers, signed_headers do
    -- We structure this code in a way so that we only have to sort once.
    canonical_headers, signed_headers = {}, {}
    local i = 0
    for name, value in pairs(lowerHeaders) do
      if value then -- ignore headers with 'false', they are used to override defaults
        i = i + 1
        local name_lower = name:lower()
        signed_headers[i] = name_lower
        canonical_headers[name_lower] = pl_string.strip(value)
      end
    end
    table.sort(signed_headers)
    for j=1, i do
      local name = signed_headers[j]
      local value = canonical_headers[name]
      canonical_headers[j] = name .. ":" .. value .. "\n"
    end
    signed_headers = table.concat(signed_headers, ";", 1, i)
    canonical_headers = table.concat(canonical_headers, nil, 1, i)
  end
  local canonical_request =
    request_method .. '\n' ..
    canonicalURI .. '\n' ..
    (canonical_querystring or "") .. '\n' ..
    canonical_headers .. '\n' ..
    signed_headers .. '\n' ..
    hex_encode(hash(req_payload or ""))

  local hashed_canonical_request = hex_encode(hash(canonical_request))
  -- Task 2: Create a String to Sign for Signature Version 4
  -- http://docs.aws.amazon.com/general/latest/gr/sigv4-create-string-to-sign.html
  local credential_scope = date .. "/" .. region .. "/" .. service .. "/aws4_request"
  local string_to_sign =
    ALGORITHM .. '\n' ..
    req_date .. '\n' ..
    credential_scope .. '\n' ..
    hashed_canonical_request

  -- Task 3: Calculate the AWS Signature Version 4
  -- http://docs.aws.amazon.com/general/latest/gr/sigv4-calculate-signature.html
  if signing_key == nil then
    signing_key = derive_signing_key(secret_key, date, region, service)
  end
  local signature = hex_encode(hmac(signing_key, string_to_sign))
  -- Task 4: Add the Signing Information to the Request
  -- http://docs.aws.amazon.com/general/latest/gr/sigv4-add-signature-to-request.html
  local authorization = ALGORITHM
    .. " Credential=" .. access_key .. "/" .. credential_scope
    .. ", SignedHeaders=" .. signed_headers
    .. ", Signature=" .. signature
    lowerHeaders.authorization = authorization

  local target = path or canonicalURI

  if notEmpty(query) or notEmpty(canonical_querystring) then
    target = target .. "?" .. (query or canonical_querystring)
  end
  local scheme = tls and "https" or "http"
  local url = scheme .. "://" .. host_header .. target

  local returned = {
    url = url,
    host = host,
    port = port,
    tls = tls,
    method = request_method,
    target = target,
    headers = lowerHeaders,
    body = req_payload,
  }

  return returned
end

return prepare_awsv4_request
