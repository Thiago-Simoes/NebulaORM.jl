# ---------------------------
# This file contains the macros for the keys in the database.
# ---------------------------
macro PrimaryKey() 
    :( "PRIMARY KEY" )
end

macro AutoIncrement()
    :( "AUTO_INCREMENT" )
end

macro NotNull()
    :( "NOT NULL" )
end

macro Unique()
    :( "UNIQUE" )
end
