# ---------------------------
# This file contains the macros for the keys in the database.
# ---------------------------
function PrimaryKey() 
    :( "PRIMARY KEY" )
end

function AutoIncrement()
    :( "AUTO_INCREMENT" )
end

function NotNull()
    :( "NOT NULL" )
end

function Unique()
    :( "UNIQUE" )
end
