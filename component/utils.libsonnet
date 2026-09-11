{
  validateTalosVersion(tver):
    local parts = std.split(tver, '.');
    assert std.length(parts) == 2 : 'Expected Talos version to contain exacty 1 dot';
    local major = std.parseJson(parts[0]);
    local minor = std.parseJson(parts[1]);
    if !std.isInteger(major) || !std.isInteger(minor) then
      error "Expected Talos version to be '<major>.<minor>', got '%s'" % tver
    else
      {
        major: major,
        minor: minor,
      },
}
