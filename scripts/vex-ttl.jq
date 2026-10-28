# Shared TTL rules for OpenVEX waivers (.github/vex-ttl.json), used by
# scripts/scout-cve-gate.sh and scripts/vex-live.sh.
#
# ttl_state(ttl; image; id; today; max; warn) -> {state, expires}
#   state: ok | soon | expired | missing | invalid
#   invalid: not a string, not a real YYYY-MM-DD date, or more than max days
#   after today. A waiver counts only for ok and soon.
def day: strptime("%Y-%m-%d") | mktime;
def real_date: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  and ((try (day | strftime("%Y-%m-%d")) catch "") as $r | $r == .);
def ttl_state(ttl; image; id; today; max; warn):
  (ttl[image][id].expires // null) as $e
  | if $e == null then {state: "missing", expires: "-"}
    elif ($e | real_date) | not then {state: "invalid", expires: ($e | tojson)}
    elif $e < today then {state: "expired", expires: $e}
    elif (($e | day) - (today | day)) > (max * 86400) then {state: "invalid", expires: $e}
    elif (($e | day) - (today | day)) <= (warn * 86400) then {state: "soon", expires: $e}
    else {state: "ok", expires: $e} end;
