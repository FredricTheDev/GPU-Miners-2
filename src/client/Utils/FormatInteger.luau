return function(value)
    return tostring(value):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end