{
  validateTalosVersion(tver):
    local parts = std.split(tver, '.');
    assert std.length(parts) == 3
           : "Expected Talos version to contain exacty 2 dots, got '%s'" % tver;
    local major = std.parseJson(parts[0]);
    local minor = std.parseJson(parts[1]);
    local patch = std.parseJson(parts[2]);
    if !std.isInteger(major) || !std.isInteger(minor) || !std.isInteger(patch) then
      error "Expected Talos version to be '<major>.<minor>.<patch>', got '%s'" % tver
    else
      {
        major: major,
        minor: minor,
        patch: patch,
      },
}
