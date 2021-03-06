#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# SQLcontext.R: SQLContext-driven functions


# Map top level R type to SQL type
getInternalType <- function(x) {
  # class of POSIXlt is c("POSIXlt" "POSIXt")
  switch(class(x)[[1]],
         integer = "integer",
         character = "string",
         logical = "boolean",
         double = "double",
         numeric = "double",
         raw = "binary",
         list = "array",
         struct = "struct",
         environment = "map",
         Date = "date",
         POSIXlt = "timestamp",
         POSIXct = "timestamp",
         stop(paste("Unsupported type for SparkDataFrame:", class(x))))
}

#' Temporary function to reroute old S3 Method call to new
#' This function is specifically implemented to remove SQLContext from the parameter list.
#' It determines the target to route the call by checking the parent of this callsite (say 'func').
#' The target should be called 'func.default'.
#' We need to check the class of x to ensure it is SQLContext/HiveContext before dispatching.
#' @param newFuncSig name of the function the user should call instead in the deprecation message
#' @param x the first parameter of the original call
#' @param ... the rest of parameter to pass along
#' @return whatever the target returns
#' @noRd
dispatchFunc <- function(newFuncSig, x, ...) {
  funcName <- as.character(sys.call(sys.parent())[[1]])
  f <- get(paste0(funcName, ".default"))
  # Strip sqlContext from list of parameters and then pass the rest along.
  contextNames <- c("org.apache.spark.sql.SQLContext",
                    "org.apache.spark.sql.hive.HiveContext",
                    "org.apache.spark.sql.hive.test.TestHiveContext",
                    "org.apache.spark.sql.SparkSession")
  if (missing(x) && length(list(...)) == 0) {
    f()
  } else if (class(x) == "jobj" &&
            any(grepl(paste(contextNames, collapse = "|"), getClassName.jobj(x)))) {
    .Deprecated(newFuncSig, old = paste0(funcName, "(sqlContext...)"))
    f(...)
  } else {
    f(x, ...)
  }
}

#' return the SparkSession
#' @note getSparkSession since 2.0.0
getSparkSession <- function() {
  if (exists(".sparkRsession", envir = .sparkREnv)) {
    get(".sparkRsession", envir = .sparkREnv)
  } else {
    stop("SparkSession not initialized")
  }
}

#' infer the SQL type
#' @note infer_type since 1.4.0
infer_type <- function(x) {
  if (is.null(x)) {
    stop("can not infer type from NULL")
  }

  type <- getInternalType(x)

  if (type == "map") {
    stopifnot(length(x) > 0)
    key <- ls(x)[[1]]
    paste0("map<string,", infer_type(get(key, x)), ">")
  } else if (type == "array") {
    stopifnot(length(x) > 0)

    paste0("array<", infer_type(x[[1]]), ">")
  } else if (type == "struct") {
    stopifnot(length(x) > 0)
    names <- names(x)
    stopifnot(!is.null(names))

    type <- lapply(seq_along(x), function(i) {
      paste0(names[[i]], ":", infer_type(x[[i]]), ",")
    })
    type <- Reduce(paste0, type)
    type <- paste0("struct<", substr(type, 1, nchar(type) - 1), ">")
  } else if (length(x) > 1 && type != "binary") {
    paste0("array<", infer_type(x[[1]]), ">")
  } else {
    type
  }
}

getDefaultSqlSource <- function() {
  sparkSession <- getSparkSession()
  conf <- callJMethod(sparkSession, "conf")
  source <- callJMethod(conf, "get", "spark.sql.sources.default", "org.apache.spark.sql.parquet")
  source
}

#' Create a SparkDataFrame
#'
#' Converts R data.frame or list into SparkDataFrame.
#'
#' @param data An RDD or list or data.frame
#' @param schema a list of column names or named list (StructType), optional
#' @return a SparkDataFrame
#' @rdname createDataFrame
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' df1 <- as.DataFrame(iris)
#' df2 <- as.DataFrame(list(3,4,5,6))
#' df3 <- createDataFrame(iris)
#' }
#' @name createDataFrame
#' @method createDataFrame default
#' @note createDataFrame since 1.4.0
# TODO(davies): support sampling and infer type from NA
createDataFrame.default <- function(data, schema = NULL, samplingRatio = 1.0) {
  sparkSession <- getSparkSession()
  if (is.data.frame(data)) {
      # get the names of columns, they will be put into RDD
      if (is.null(schema)) {
        schema <- names(data)
      }

      # get rid of factor type
      cleanCols <- function(x) {
        if (is.factor(x)) {
          as.character(x)
        } else {
          x
        }
      }

      # drop factors and wrap lists
      data <- setNames(lapply(data, cleanCols), NULL)

      # check if all columns have supported type
      lapply(data, getInternalType)

      # convert to rows
      args <- list(FUN = list, SIMPLIFY = FALSE, USE.NAMES = FALSE)
      data <- do.call(mapply, append(args, data))
  }
  if (is.list(data)) {
    sc <- callJStatic("org.apache.spark.sql.api.r.SQLUtils", "getJavaSparkContext", sparkSession)
    rdd <- parallelize(sc, data)
  } else if (inherits(data, "RDD")) {
    rdd <- data
  } else {
    stop(paste("unexpected type:", class(data)))
  }

  if (is.null(schema) || (!inherits(schema, "structType") && is.null(names(schema)))) {
    row <- first(rdd)
    names <- if (is.null(schema)) {
      names(row)
    } else {
      as.list(schema)
    }
    if (is.null(names)) {
      names <- lapply(1:length(row), function(x) {
        paste("_", as.character(x), sep = "")
      })
    }

    # SPAKR-SQL does not support '.' in column name, so replace it with '_'
    # TODO(davies): remove this once SPARK-2775 is fixed
    names <- lapply(names, function(n) {
      nn <- gsub("[.]", "_", n)
      if (nn != n) {
        warning(paste("Use", nn, "instead of", n, " as column name"))
      }
      nn
    })

    types <- lapply(row, infer_type)
    fields <- lapply(1:length(row), function(i) {
      structField(names[[i]], types[[i]], TRUE)
    })
    schema <- do.call(structType, fields)
  }

  stopifnot(class(schema) == "structType")

  jrdd <- getJRDD(lapply(rdd, function(x) x), "row")
  srdd <- callJMethod(jrdd, "rdd")
  sdf <- callJStatic("org.apache.spark.sql.api.r.SQLUtils", "createDF",
                     srdd, schema$jobj, sparkSession)
  dataFrame(sdf)
}

createDataFrame <- function(x, ...) {
  dispatchFunc("createDataFrame(data, schema = NULL, samplingRatio = 1.0)", x, ...)
}

#' @rdname createDataFrame
#' @aliases createDataFrame
#' @export
#' @method as.DataFrame default
#' @note as.DataFrame since 1.6.0
as.DataFrame.default <- function(data, schema = NULL, samplingRatio = 1.0) {
  createDataFrame(data, schema, samplingRatio)
}

as.DataFrame <- function(x, ...) {
  dispatchFunc("as.DataFrame(data, schema = NULL, samplingRatio = 1.0)", x, ...)
}

#' toDF
#'
#' Converts an RDD to a SparkDataFrame by infer the types.
#'
#' @param x An RDD
#'
#' @rdname SparkDataFrame
#' @noRd
#' @examples
#'\dontrun{
#' sparkR.session()
#' rdd <- lapply(parallelize(sc, 1:10), function(x) list(a=x, b=as.character(x)))
#' df <- toDF(rdd)
#'}
setGeneric("toDF", function(x, ...) { standardGeneric("toDF") })

setMethod("toDF", signature(x = "RDD"),
          function(x, ...) {
            createDataFrame(x, ...)
          })

#' Create a SparkDataFrame from a JSON file.
#'
#' Loads a JSON file (one object per line), returning the result as a SparkDataFrame
#' It goes through the entire dataset once to determine the schema.
#'
#' @param path Path of file to read. A vector of multiple paths is allowed.
#' @return SparkDataFrame
#' @rdname read.json
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' path <- "path/to/file.json"
#' df <- read.json(path)
#' df <- jsonFile(path)
#' }
#' @name read.json
#' @method read.json default
#' @note read.json since 1.6.0
read.json.default <- function(path) {
  sparkSession <- getSparkSession()
  # Allow the user to have a more flexible definiton of the text file path
  paths <- as.list(suppressWarnings(normalizePath(path)))
  read <- callJMethod(sparkSession, "read")
  sdf <- callJMethod(read, "json", paths)
  dataFrame(sdf)
}

read.json <- function(x, ...) {
  dispatchFunc("read.json(path)", x, ...)
}

#' @rdname read.json
#' @name jsonFile
#' @export
#' @method jsonFile default
#' @note jsonFile since 1.4.0
jsonFile.default <- function(path) {
  .Deprecated("read.json")
  read.json(path)
}

jsonFile <- function(x, ...) {
  dispatchFunc("jsonFile(path)", x, ...)
}

#' JSON RDD
#'
#' Loads an RDD storing one JSON object per string as a SparkDataFrame.
#'
#' @param sqlContext SQLContext to use
#' @param rdd An RDD of JSON string
#' @param schema A StructType object to use as schema
#' @param samplingRatio The ratio of simpling used to infer the schema
#' @return A SparkDataFrame
#' @noRd
#' @examples
#'\dontrun{
#' sparkR.session()
#' rdd <- texFile(sc, "path/to/json")
#' df <- jsonRDD(sqlContext, rdd)
#'}

# TODO: remove - this method is no longer exported
# TODO: support schema
jsonRDD <- function(sqlContext, rdd, schema = NULL, samplingRatio = 1.0) {
  .Deprecated("read.json")
  rdd <- serializeToString(rdd)
  if (is.null(schema)) {
    read <- callJMethod(sqlContext, "read")
    # samplingRatio is deprecated
    sdf <- callJMethod(read, "json", callJMethod(getJRDD(rdd), "rdd"))
    dataFrame(sdf)
  } else {
    stop("not implemented")
  }
}

#' Create a SparkDataFrame from an ORC file.
#'
#' Loads an ORC file, returning the result as a SparkDataFrame.
#'
#' @param path Path of file to read.
#' @return SparkDataFrame
#' @rdname read.orc
#' @export
#' @name read.orc
#' @note read.orc since 2.0.0
read.orc <- function(path) {
  sparkSession <- getSparkSession()
  # Allow the user to have a more flexible definiton of the ORC file path
  path <- suppressWarnings(normalizePath(path))
  read <- callJMethod(sparkSession, "read")
  sdf <- callJMethod(read, "orc", path)
  dataFrame(sdf)
}

#' Create a SparkDataFrame from a Parquet file.
#'
#' Loads a Parquet file, returning the result as a SparkDataFrame.
#'
#' @param path Path of file to read. A vector of multiple paths is allowed.
#' @return SparkDataFrame
#' @rdname read.parquet
#' @export
#' @name read.parquet
#' @method read.parquet default
#' @note read.parquet since 1.6.0
read.parquet.default <- function(path) {
  sparkSession <- getSparkSession()
  # Allow the user to have a more flexible definiton of the Parquet file path
  paths <- as.list(suppressWarnings(normalizePath(path)))
  read <- callJMethod(sparkSession, "read")
  sdf <- callJMethod(read, "parquet", paths)
  dataFrame(sdf)
}

read.parquet <- function(x, ...) {
  dispatchFunc("read.parquet(...)", x, ...)
}

#' @rdname read.parquet
#' @name parquetFile
#' @export
#' @method parquetFile default
#' @note parquetFile since 1.4.0
parquetFile.default <- function(...) {
  .Deprecated("read.parquet")
  read.parquet(unlist(list(...)))
}

parquetFile <- function(x, ...) {
  dispatchFunc("parquetFile(...)", x, ...)
}

#' Create a SparkDataFrame from a text file.
#'
#' Loads text files and returns a SparkDataFrame whose schema starts with
#' a string column named "value", and followed by partitioned columns if
#' there are any.
#'
#' Each line in the text file is a new row in the resulting SparkDataFrame.
#'
#' @param path Path of file to read. A vector of multiple paths is allowed.
#' @return SparkDataFrame
#' @rdname read.text
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' path <- "path/to/file.txt"
#' df <- read.text(path)
#' }
#' @name read.text
#' @method read.text default
#' @note read.text since 1.6.1
read.text.default <- function(path) {
  sparkSession <- getSparkSession()
  # Allow the user to have a more flexible definiton of the text file path
  paths <- as.list(suppressWarnings(normalizePath(path)))
  read <- callJMethod(sparkSession, "read")
  sdf <- callJMethod(read, "text", paths)
  dataFrame(sdf)
}

read.text <- function(x, ...) {
  dispatchFunc("read.text(path)", x, ...)
}

#' SQL Query
#'
#' Executes a SQL query using Spark, returning the result as a SparkDataFrame.
#'
#' @param sqlQuery A character vector containing the SQL query
#' @return SparkDataFrame
#' @rdname sql
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' path <- "path/to/file.json"
#' df <- read.json(path)
#' createOrReplaceTempView(df, "table")
#' new_df <- sql("SELECT * FROM table")
#' }
#' @name sql
#' @method sql default
#' @note sql since 1.4.0
sql.default <- function(sqlQuery) {
  sparkSession <- getSparkSession()
  sdf <- callJMethod(sparkSession, "sql", sqlQuery)
  dataFrame(sdf)
}

sql <- function(x, ...) {
  dispatchFunc("sql(sqlQuery)", x, ...)
}

#' Create a SparkDataFrame from a SparkSQL Table
#'
#' Returns the specified Table as a SparkDataFrame.  The Table must have already been registered
#' in the SQLContext.
#'
#' @param tableName The SparkSQL Table to convert to a SparkDataFrame.
#' @return SparkDataFrame
#' @rdname tableToDF
#' @name tableToDF
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' path <- "path/to/file.json"
#' df <- read.json(path)
#' createOrReplaceTempView(df, "table")
#' new_df <- tableToDF("table")
#' }
#' @note tableToDF since 2.0.0
tableToDF <- function(tableName) {
  sparkSession <- getSparkSession()
  sdf <- callJMethod(sparkSession, "table", tableName)
  dataFrame(sdf)
}

#' Tables
#'
#' Returns a SparkDataFrame containing names of tables in the given database.
#'
#' @param databaseName name of the database
#' @return a SparkDataFrame
#' @rdname tables
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' tables("hive")
#' }
#' @name tables
#' @method tables default
#' @note tables since 1.4.0
tables.default <- function(databaseName = NULL) {
  sparkSession <- getSparkSession()
  jdf <- callJStatic("org.apache.spark.sql.api.r.SQLUtils", "getTables", sparkSession, databaseName)
  dataFrame(jdf)
}

tables <- function(x, ...) {
  dispatchFunc("tables(databaseName = NULL)", x, ...)
}

#' Table Names
#'
#' Returns the names of tables in the given database as an array.
#'
#' @param databaseName name of the database
#' @return a list of table names
#' @rdname tableNames
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' tableNames("hive")
#' }
#' @name tableNames
#' @method tableNames default
#' @note tableNames since 1.4.0
tableNames.default <- function(databaseName = NULL) {
  sparkSession <- getSparkSession()
  callJStatic("org.apache.spark.sql.api.r.SQLUtils",
              "getTableNames",
              sparkSession,
              databaseName)
}

tableNames <- function(x, ...) {
  dispatchFunc("tableNames(databaseName = NULL)", x, ...)
}

#' Cache Table
#'
#' Caches the specified table in-memory.
#'
#' @param tableName The name of the table being cached
#' @return SparkDataFrame
#' @rdname cacheTable
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' path <- "path/to/file.json"
#' df <- read.json(path)
#' createOrReplaceTempView(df, "table")
#' cacheTable("table")
#' }
#' @name cacheTable
#' @method cacheTable default
#' @note cacheTable since 1.4.0
cacheTable.default <- function(tableName) {
  sparkSession <- getSparkSession()
  catalog <- callJMethod(sparkSession, "catalog")
  callJMethod(catalog, "cacheTable", tableName)
}

cacheTable <- function(x, ...) {
  dispatchFunc("cacheTable(tableName)", x, ...)
}

#' Uncache Table
#'
#' Removes the specified table from the in-memory cache.
#'
#' @param tableName The name of the table being uncached
#' @return SparkDataFrame
#' @rdname uncacheTable
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' path <- "path/to/file.json"
#' df <- read.json(path)
#' createOrReplaceTempView(df, "table")
#' uncacheTable("table")
#' }
#' @name uncacheTable
#' @method uncacheTable default
#' @note uncacheTable since 1.4.0
uncacheTable.default <- function(tableName) {
  sparkSession <- getSparkSession()
  catalog <- callJMethod(sparkSession, "catalog")
  callJMethod(catalog, "uncacheTable", tableName)
}

uncacheTable <- function(x, ...) {
  dispatchFunc("uncacheTable(tableName)", x, ...)
}

#' Clear Cache
#'
#' Removes all cached tables from the in-memory cache.
#'
#' @rdname clearCache
#' @export
#' @examples
#' \dontrun{
#' clearCache()
#' }
#' @name clearCache
#' @method clearCache default
#' @note clearCache since 1.4.0
clearCache.default <- function() {
  sparkSession <- getSparkSession()
  catalog <- callJMethod(sparkSession, "catalog")
  callJMethod(catalog, "clearCache")
}

clearCache <- function() {
  dispatchFunc("clearCache()")
}

#' (Deprecated) Drop Temporary Table
#'
#' Drops the temporary table with the given table name in the catalog.
#' If the table has been cached/persisted before, it's also unpersisted.
#'
#' @param tableName The name of the SparkSQL table to be dropped.
#' @seealso \link{dropTempView}
#' @rdname dropTempTable-deprecated
#' @export
#' @examples
#' \dontrun{
#' sparkR.session()
#' df <- read.df(path, "parquet")
#' createOrReplaceTempView(df, "table")
#' dropTempTable("table")
#' }
#' @name dropTempTable
#' @method dropTempTable default
#' @note dropTempTable since 1.4.0
dropTempTable.default <- function(tableName) {
  if (class(tableName) != "character") {
    stop("tableName must be a string.")
  }
  dropTempView(tableName)
}

dropTempTable <- function(x, ...) {
  .Deprecated("dropTempView")
  dispatchFunc("dropTempView(viewName)", x, ...)
}

#' Drops the temporary view with the given view name in the catalog.
#'
#' Drops the temporary view with the given view name in the catalog.
#' If the view has been cached before, then it will also be uncached.
#'
#' @param viewName the name of the view to be dropped.
#' @rdname dropTempView
#' @name dropTempView
#' @export
#' @examples
#' \dontrun{
#' sparkR.session()
#' df <- read.df(path, "parquet")
#' createOrReplaceTempView(df, "table")
#' dropTempView("table")
#' }
#' @note since 2.0.0

dropTempView <- function(viewName) {
  sparkSession <- getSparkSession()
  if (class(viewName) != "character") {
    stop("viewName must be a string.")
  }
  catalog <- callJMethod(sparkSession, "catalog")
  callJMethod(catalog, "dropTempView", viewName)
}

#' Load a SparkDataFrame
#'
#' Returns the dataset in a data source as a SparkDataFrame
#'
#' The data source is specified by the `source` and a set of options(...).
#' If `source` is not specified, the default data source configured by
#' "spark.sql.sources.default" will be used.
#'
#' @param path The path of files to load
#' @param source The name of external data source
#' @param schema The data schema defined in structType
#' @return SparkDataFrame
#' @rdname read.df
#' @name read.df
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' df1 <- read.df("path/to/file.json", source = "json")
#' schema <- structType(structField("name", "string"),
#'                      structField("info", "map<string,double>"))
#' df2 <- read.df(mapTypeJsonPath, "json", schema)
#' df3 <- loadDF("data/test_table", "parquet", mergeSchema = "true")
#' }
#' @name read.df
#' @method read.df default
#' @note read.df since 1.4.0
read.df.default <- function(path = NULL, source = NULL, schema = NULL, ...) {
  sparkSession <- getSparkSession()
  options <- varargsToEnv(...)
  if (!is.null(path)) {
    options[["path"]] <- path
  }
  if (is.null(source)) {
    source <- getDefaultSqlSource()
  }
  if (!is.null(schema)) {
    stopifnot(class(schema) == "structType")
    sdf <- callJStatic("org.apache.spark.sql.api.r.SQLUtils", "loadDF", sparkSession, source,
                       schema$jobj, options)
  } else {
    sdf <- callJStatic("org.apache.spark.sql.api.r.SQLUtils",
                       "loadDF", sparkSession, source, options)
  }
  dataFrame(sdf)
}

read.df <- function(x, ...) {
  dispatchFunc("read.df(path = NULL, source = NULL, schema = NULL, ...)", x, ...)
}

#' @rdname read.df
#' @name loadDF
#' @method loadDF default
#' @note loadDF since 1.6.0
loadDF.default <- function(path = NULL, source = NULL, schema = NULL, ...) {
  read.df(path, source, schema, ...)
}

loadDF <- function(x, ...) {
  dispatchFunc("loadDF(path = NULL, source = NULL, schema = NULL, ...)", x, ...)
}

#' Create an external table
#'
#' Creates an external table based on the dataset in a data source,
#' Returns a SparkDataFrame associated with the external table.
#'
#' The data source is specified by the `source` and a set of options(...).
#' If `source` is not specified, the default data source configured by
#' "spark.sql.sources.default" will be used.
#'
#' @param tableName A name of the table
#' @param path The path of files to load
#' @param source the name of external data source
#' @return SparkDataFrame
#' @rdname createExternalTable
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' df <- createExternalTable("myjson", path="path/to/json", source="json")
#' }
#' @name createExternalTable
#' @method createExternalTable default
#' @note createExternalTable since 1.4.0
createExternalTable.default <- function(tableName, path = NULL, source = NULL, ...) {
  sparkSession <- getSparkSession()
  options <- varargsToEnv(...)
  if (!is.null(path)) {
    options[["path"]] <- path
  }
  catalog <- callJMethod(sparkSession, "catalog")
  sdf <- callJMethod(catalog, "createExternalTable", tableName, source, options)
  dataFrame(sdf)
}

createExternalTable <- function(x, ...) {
  dispatchFunc("createExternalTable(tableName, path = NULL, source = NULL, ...)", x, ...)
}

#' Create a SparkDataFrame representing the database table accessible via JDBC URL
#'
#' Additional JDBC database connection properties can be set (...)
#'
#' Only one of partitionColumn or predicates should be set. Partitions of the table will be
#' retrieved in parallel based on the `numPartitions` or by the predicates.
#'
#' Don't create too many partitions in parallel on a large cluster; otherwise Spark might crash
#' your external database systems.
#'
#' @param url JDBC database url of the form `jdbc:subprotocol:subname`
#' @param tableName the name of the table in the external database
#' @param partitionColumn the name of a column of integral type that will be used for partitioning
#' @param lowerBound the minimum value of `partitionColumn` used to decide partition stride
#' @param upperBound the maximum value of `partitionColumn` used to decide partition stride
#' @param numPartitions the number of partitions, This, along with `lowerBound` (inclusive),
#'                      `upperBound` (exclusive), form partition strides for generated WHERE
#'                      clause expressions used to split the column `partitionColumn` evenly.
#'                      This defaults to SparkContext.defaultParallelism when unset.
#' @param predicates a list of conditions in the where clause; each one defines one partition
#' @return SparkDataFrame
#' @rdname read.jdbc
#' @name read.jdbc
#' @export
#' @examples
#'\dontrun{
#' sparkR.session()
#' jdbcUrl <- "jdbc:mysql://localhost:3306/databasename"
#' df <- read.jdbc(jdbcUrl, "table", predicates = list("field<=123"), user = "username")
#' df2 <- read.jdbc(jdbcUrl, "table2", partitionColumn = "index", lowerBound = 0,
#'                  upperBound = 10000, user = "username", password = "password")
#' }
#' @note read.jdbc since 2.0.0
read.jdbc <- function(url, tableName,
                      partitionColumn = NULL, lowerBound = NULL, upperBound = NULL,
                      numPartitions = 0L, predicates = list(), ...) {
  jprops <- varargsToJProperties(...)
  sparkSession <- getSparkSession()
  read <- callJMethod(sparkSession, "read")
  if (!is.null(partitionColumn)) {
    if (is.null(numPartitions) || numPartitions == 0) {
      sc <- callJMethod(sparkSession, "sparkContext")
      numPartitions <- callJMethod(sc, "defaultParallelism")
    } else {
      numPartitions <- numToInt(numPartitions)
    }
    sdf <- callJMethod(read, "jdbc", url, tableName, as.character(partitionColumn),
                       numToInt(lowerBound), numToInt(upperBound), numPartitions, jprops)
  } else if (length(predicates) > 0) {
    sdf <- callJMethod(read, "jdbc", url, tableName, as.list(as.character(predicates)), jprops)
  } else {
    sdf <- callJMethod(read, "jdbc", url, tableName, jprops)
  }
  dataFrame(sdf)
}
