CREATE TABLE authors ( id   INTEGER PRIMARY KEY,
                              name TEXT NOT NULL COLLATE NOCASE,
                              sort TEXT COLLATE NOCASE,
                              link TEXT NOT NULL DEFAULT "",
                              UNIQUE(name)
                             );
CREATE TABLE books ( id      INTEGER PRIMARY KEY AUTOINCREMENT,
                             title     TEXT NOT NULL DEFAULT 'Unknown' COLLATE NOCASE,
                             sort      TEXT COLLATE NOCASE,
                             timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                             pubdate   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                             series_index REAL NOT NULL DEFAULT 1.0,
                             author_sort TEXT COLLATE NOCASE,
                             path TEXT NOT NULL DEFAULT "",
                             uuid TEXT,
                             has_cover BOOL DEFAULT 0,
                             last_modified TIMESTAMP NOT NULL DEFAULT "2000-01-01 00:00:00+00:00");
CREATE TABLE books_authors_link ( id INTEGER PRIMARY KEY,
                                          book INTEGER NOT NULL,
                                          author INTEGER NOT NULL,
                                          UNIQUE(book, author)
                                        );
CREATE TABLE books_languages_link ( id INTEGER PRIMARY KEY,
                                            book INTEGER NOT NULL,
                                            lang_code INTEGER NOT NULL,
                                            item_order INTEGER NOT NULL DEFAULT 0,
                                            UNIQUE(book, lang_code)
        );
CREATE TABLE books_plugin_data(id INTEGER PRIMARY KEY,
                                     book INTEGER NOT NULL,
                                     name TEXT NOT NULL,
                                     val TEXT NOT NULL,
                                     UNIQUE(book,name));
CREATE TABLE books_publishers_link ( id INTEGER PRIMARY KEY,
                                          book INTEGER NOT NULL,
                                          publisher INTEGER NOT NULL,
                                          UNIQUE(book)
                                        );
CREATE TABLE books_ratings_link ( id INTEGER PRIMARY KEY,
                                          book INTEGER NOT NULL,
                                          rating INTEGER NOT NULL,
                                          UNIQUE(book, rating)
                                        );
CREATE TABLE books_series_link ( id INTEGER PRIMARY KEY,
                                          book INTEGER NOT NULL,
                                          series INTEGER NOT NULL,
                                          UNIQUE(book)
                                        );
CREATE TABLE books_tags_link ( id INTEGER PRIMARY KEY,
                                          book INTEGER NOT NULL,
                                          tag INTEGER NOT NULL,
                                          UNIQUE(book, tag)
                                        );
CREATE TABLE comments ( id INTEGER PRIMARY KEY,
                              book INTEGER NOT NULL,
                              text TEXT NOT NULL COLLATE NOCASE,
                              UNIQUE(book)
                            );
CREATE TABLE conversion_options ( id INTEGER PRIMARY KEY,
                                          format TEXT NOT NULL COLLATE NOCASE,
                                          book INTEGER,
                                          data BLOB NOT NULL,
                                          UNIQUE(format,book)
                                        );
CREATE TABLE custom_columns (
                    id       INTEGER PRIMARY KEY AUTOINCREMENT,
                    label    TEXT NOT NULL,
                    name     TEXT NOT NULL,
                    datatype TEXT NOT NULL,
                    mark_for_delete   BOOL DEFAULT 0 NOT NULL,
                    editable BOOL DEFAULT 1 NOT NULL,
                    display  TEXT DEFAULT "{}" NOT NULL,
                    is_multiple BOOL DEFAULT 0 NOT NULL,
                    normalized BOOL NOT NULL,
                    UNIQUE(label)
                );
CREATE TABLE data ( id     INTEGER PRIMARY KEY,
                            book   INTEGER NOT NULL,
                            format TEXT NOT NULL COLLATE NOCASE,
                            uncompressed_size INTEGER NOT NULL,
                            name TEXT NOT NULL,
                            UNIQUE(book, format)
);
CREATE TABLE feeds ( id   INTEGER PRIMARY KEY,
                              title TEXT NOT NULL,
                              script TEXT NOT NULL,
                              UNIQUE(title)
                             );
CREATE TABLE identifiers  ( id     INTEGER PRIMARY KEY,
                                    book   INTEGER NOT NULL,
                                    type   TEXT NOT NULL DEFAULT "isbn" COLLATE NOCASE,
                                    val    TEXT NOT NULL COLLATE NOCASE,
                                    UNIQUE(book, type)
        );
CREATE TABLE languages    ( id        INTEGER PRIMARY KEY,
                                    lang_code TEXT NOT NULL COLLATE NOCASE, link TEXT NOT NULL DEFAULT '',
                                    UNIQUE(lang_code)
        );
CREATE TABLE library_id ( id   INTEGER PRIMARY KEY,
                                  uuid TEXT NOT NULL,
                                  UNIQUE(uuid)
        );
CREATE TABLE metadata_dirtied(id INTEGER PRIMARY KEY,
                             book INTEGER NOT NULL,
                             UNIQUE(book));
CREATE TABLE annotations_dirtied(id INTEGER PRIMARY KEY,
                             book INTEGER NOT NULL,
                             UNIQUE(book));
CREATE TABLE preferences(id INTEGER PRIMARY KEY,
                                 key TEXT NOT NULL,
                                 val TEXT NOT NULL,
                                 UNIQUE(key));
CREATE TABLE publishers ( id   INTEGER PRIMARY KEY,
                                  name TEXT NOT NULL COLLATE NOCASE,
                                  sort TEXT COLLATE NOCASE, link TEXT NOT NULL DEFAULT '',
                                  UNIQUE(name)
                             );
CREATE TABLE ratings ( id   INTEGER PRIMARY KEY,
                               rating INTEGER CHECK(rating > -1 AND rating < 11), link TEXT NOT NULL DEFAULT '',
                               UNIQUE (rating)
                             );
CREATE TABLE series ( id   INTEGER PRIMARY KEY,
                              name TEXT NOT NULL COLLATE NOCASE,
                              sort TEXT COLLATE NOCASE, link TEXT NOT NULL DEFAULT '',
                              UNIQUE (name)
                             );
CREATE TABLE tags ( id   INTEGER PRIMARY KEY,
                            name TEXT NOT NULL COLLATE NOCASE, link TEXT NOT NULL DEFAULT '',
                            UNIQUE (name)
                             );
CREATE TABLE last_read_positions ( id INTEGER PRIMARY KEY,
	book INTEGER NOT NULL,
	format TEXT NOT NULL COLLATE NOCASE,
	user TEXT NOT NULL,
	device TEXT NOT NULL,
	cfi TEXT NOT NULL,
	epoch REAL NOT NULL,
	pos_frac REAL NOT NULL DEFAULT 0,
	UNIQUE(user, device, book, format)
);
CREATE TABLE annotations ( id INTEGER PRIMARY KEY,
	book INTEGER NOT NULL,
	format TEXT NOT NULL COLLATE NOCASE,
	user_type TEXT NOT NULL,
	user TEXT NOT NULL,
	timestamp REAL NOT NULL,
	annot_id TEXT NOT NULL,
	annot_type TEXT NOT NULL,
	annot_data TEXT NOT NULL,
    searchable_text TEXT NOT NULL DEFAULT "",
    UNIQUE(book, user_type, user, format, annot_type, annot_id)
);
CREATE TABLE custom_column_1(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    book  INTEGER,
                    value INT NOT NULL ,
                    UNIQUE(book));
CREATE TABLE custom_column_2(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    book  INTEGER,
                    value TEXT NOT NULL COLLATE NOCASE,
                    UNIQUE(book));
CREATE TABLE custom_column_3(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value INT NOT NULL , link TEXT NOT NULL DEFAULT '',
                    UNIQUE(value));
CREATE TABLE books_custom_column_3_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE custom_column_5(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_5_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE custom_column_7(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    book  INTEGER,
                    value INT NOT NULL ,
                    UNIQUE(book));
CREATE TABLE custom_column_8(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_8_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE custom_column_9(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    book  INTEGER,
                    value TEXT NOT NULL COLLATE NOCASE,
                    UNIQUE(book));
CREATE TABLE custom_column_10(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_10_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE custom_column_11(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    book  INTEGER,
                    value INT NOT NULL ,
                    UNIQUE(book));
CREATE TABLE custom_column_12(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_12_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE custom_column_14(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_14_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE custom_column_16(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_16_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE custom_column_17(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_17_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE VIRTUAL TABLE annotations_fts USING fts5(searchable_text, content = 'annotations', content_rowid = 'id', tokenize = 'unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE annotations_fts_stemmed USING fts5(searchable_text, content = 'annotations', content_rowid = 'id', tokenize = 'porter unicode61 remove_diacritics 2');
CREATE TABLE custom_column_18(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    book  INTEGER,
                    value TEXT NOT NULL COLLATE NOCASE,
                    UNIQUE(book));
CREATE TABLE custom_column_20(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_20_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE books_pages_link (
                book INTEGER PRIMARY KEY,
                pages INTEGER DEFAULT 0 NOT NULL,
                algorithm INTEGER DEFAULT 0 NOT NULL,
                format TEXT DEFAULT '' NOT NULL COLLATE NOCASE,
                format_size INTEGER DEFAULT 0 NOT NULL,
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                needs_scan INTEGER NOT NULL DEFAULT 0 CHECK(needs_scan IN (0, 1)),
                FOREIGN KEY (book) REFERENCES books(id) ON DELETE CASCADE
            );
CREATE TABLE custom_column_21(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    value TEXT NOT NULL COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT "",
                    UNIQUE(value));
CREATE TABLE books_custom_column_21_link(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book INTEGER NOT NULL,
                    value INTEGER NOT NULL,
                    
                    UNIQUE(book, value)
                    );
CREATE TABLE custom_column_22(
                    id    INTEGER PRIMARY KEY AUTOINCREMENT,
                    book  INTEGER,
                    value BOOL NOT NULL ,
                    UNIQUE(book));
CREATE VIEW tag_browser_authors AS SELECT
                    id,
                    name,
                    (SELECT COUNT(id) FROM books_authors_link WHERE author=authors.id) count,
                    (SELECT AVG(ratings.rating)
                     FROM books_authors_link AS tl, books_ratings_link AS bl, ratings
                     WHERE tl.author=authors.id AND bl.book=tl.book AND
                     ratings.id = bl.rating AND ratings.rating <> 0) avg_rating,
                     sort AS sort
                FROM authors;
CREATE VIEW tag_browser_filtered_authors AS SELECT
                    id,
                    name,
                    (SELECT COUNT(books_authors_link.id) FROM books_authors_link WHERE
                        author=authors.id AND books_list_filter(book)) count,
                    (SELECT AVG(ratings.rating)
                     FROM books_authors_link AS tl, books_ratings_link AS bl, ratings
                     WHERE tl.author=authors.id AND bl.book=tl.book AND
                     ratings.id = bl.rating AND ratings.rating <> 0 AND
                     books_list_filter(bl.book)) avg_rating,
                     sort AS sort
                FROM authors;
CREATE VIEW tag_browser_filtered_publishers AS SELECT
                    id,
                    name,
                    (SELECT COUNT(books_publishers_link.id) FROM books_publishers_link WHERE
                        publisher=publishers.id AND books_list_filter(book)) count,
                    (SELECT AVG(ratings.rating)
                     FROM books_publishers_link AS tl, books_ratings_link AS bl, ratings
                     WHERE tl.publisher=publishers.id AND bl.book=tl.book AND
                     ratings.id = bl.rating AND ratings.rating <> 0 AND
                     books_list_filter(bl.book)) avg_rating,
                     name AS sort
                FROM publishers;
CREATE VIEW tag_browser_filtered_ratings AS SELECT
                    id,
                    rating,
                    (SELECT COUNT(books_ratings_link.id) FROM books_ratings_link WHERE
                        rating=ratings.id AND books_list_filter(book)) count,
                    (SELECT AVG(ratings.rating)
                     FROM books_ratings_link AS tl, books_ratings_link AS bl, ratings
                     WHERE tl.rating=ratings.id AND bl.book=tl.book AND
                     ratings.id = bl.rating AND ratings.rating <> 0 AND
                     books_list_filter(bl.book)) avg_rating,
                     rating AS sort
                FROM ratings;
CREATE VIEW tag_browser_filtered_tags AS SELECT
                    id,
                    name,
                    (SELECT COUNT(books_tags_link.id) FROM books_tags_link WHERE
                        tag=tags.id AND books_list_filter(book)) count,
                    (SELECT AVG(ratings.rating)
                     FROM books_tags_link AS tl, books_ratings_link AS bl, ratings
                     WHERE tl.tag=tags.id AND bl.book=tl.book AND
                     ratings.id = bl.rating AND ratings.rating <> 0 AND
                     books_list_filter(bl.book)) avg_rating,
                     name AS sort
                FROM tags;
CREATE VIEW tag_browser_publishers AS SELECT
                    id,
                    name,
                    (SELECT COUNT(id) FROM books_publishers_link WHERE publisher=publishers.id) count,
                    (SELECT AVG(ratings.rating)
                     FROM books_publishers_link AS tl, books_ratings_link AS bl, ratings
                     WHERE tl.publisher=publishers.id AND bl.book=tl.book AND
                     ratings.id = bl.rating AND ratings.rating <> 0) avg_rating,
                     name AS sort
                FROM publishers;
CREATE VIEW tag_browser_ratings AS SELECT
                    id,
                    rating,
                    (SELECT COUNT(id) FROM books_ratings_link WHERE rating=ratings.id) count,
                    (SELECT AVG(ratings.rating)
                     FROM books_ratings_link AS tl, books_ratings_link AS bl, ratings
                     WHERE tl.rating=ratings.id AND bl.book=tl.book AND
                     ratings.id = bl.rating AND ratings.rating <> 0) avg_rating,
                     rating AS sort
                FROM ratings;
CREATE VIEW tag_browser_tags AS SELECT
                    id,
                    name,
                    (SELECT COUNT(id) FROM books_tags_link WHERE tag=tags.id) count,
                    (SELECT AVG(ratings.rating)
                     FROM books_tags_link AS tl, books_ratings_link AS bl, ratings
                     WHERE tl.tag=tags.id AND bl.book=tl.book AND
                     ratings.id = bl.rating AND ratings.rating <> 0) avg_rating,
                     name AS sort
                FROM tags;
CREATE VIEW tag_browser_custom_column_3 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_3_link WHERE value=custom_column_3.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_3_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_3_link.value=custom_column_3.id and bl.book=books_custom_column_3_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_3;
CREATE VIEW tag_browser_filtered_custom_column_3 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_3_link.id) FROM books_custom_column_3_link WHERE value=custom_column_3.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_3_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_3_link.value=custom_column_3.id AND bl.book=books_custom_column_3_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_3;
CREATE VIEW tag_browser_custom_column_5 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_5_link WHERE value=custom_column_5.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_5_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_5_link.value=custom_column_5.id and bl.book=books_custom_column_5_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_5;
CREATE VIEW tag_browser_filtered_custom_column_5 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_5_link.id) FROM books_custom_column_5_link WHERE value=custom_column_5.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_5_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_5_link.value=custom_column_5.id AND bl.book=books_custom_column_5_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_5;
CREATE VIEW tag_browser_custom_column_8 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_8_link WHERE value=custom_column_8.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_8_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_8_link.value=custom_column_8.id and bl.book=books_custom_column_8_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_8;
CREATE VIEW tag_browser_filtered_custom_column_8 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_8_link.id) FROM books_custom_column_8_link WHERE value=custom_column_8.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_8_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_8_link.value=custom_column_8.id AND bl.book=books_custom_column_8_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_8;
CREATE VIEW tag_browser_custom_column_10 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_10_link WHERE value=custom_column_10.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_10_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_10_link.value=custom_column_10.id and bl.book=books_custom_column_10_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_10;
CREATE VIEW tag_browser_filtered_custom_column_10 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_10_link.id) FROM books_custom_column_10_link WHERE value=custom_column_10.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_10_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_10_link.value=custom_column_10.id AND bl.book=books_custom_column_10_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_10;
CREATE VIEW tag_browser_custom_column_12 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_12_link WHERE value=custom_column_12.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_12_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_12_link.value=custom_column_12.id and bl.book=books_custom_column_12_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_12;
CREATE VIEW tag_browser_filtered_custom_column_12 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_12_link.id) FROM books_custom_column_12_link WHERE value=custom_column_12.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_12_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_12_link.value=custom_column_12.id AND bl.book=books_custom_column_12_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_12;
CREATE VIEW tag_browser_custom_column_14 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_14_link WHERE value=custom_column_14.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_14_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_14_link.value=custom_column_14.id and bl.book=books_custom_column_14_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_14;
CREATE VIEW tag_browser_filtered_custom_column_14 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_14_link.id) FROM books_custom_column_14_link WHERE value=custom_column_14.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_14_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_14_link.value=custom_column_14.id AND bl.book=books_custom_column_14_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_14;
CREATE VIEW tag_browser_custom_column_16 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_16_link WHERE value=custom_column_16.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_16_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_16_link.value=custom_column_16.id and bl.book=books_custom_column_16_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_16;
CREATE VIEW tag_browser_filtered_custom_column_16 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_16_link.id) FROM books_custom_column_16_link WHERE value=custom_column_16.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_16_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_16_link.value=custom_column_16.id AND bl.book=books_custom_column_16_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_16;
CREATE VIEW tag_browser_custom_column_17 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_17_link WHERE value=custom_column_17.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_17_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_17_link.value=custom_column_17.id and bl.book=books_custom_column_17_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_17;
CREATE VIEW tag_browser_filtered_custom_column_17 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_17_link.id) FROM books_custom_column_17_link WHERE value=custom_column_17.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_17_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_17_link.value=custom_column_17.id AND bl.book=books_custom_column_17_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_17;
CREATE VIEW tag_browser_custom_column_20 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_20_link WHERE value=custom_column_20.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_20_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_20_link.value=custom_column_20.id and bl.book=books_custom_column_20_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_20;
CREATE VIEW tag_browser_filtered_custom_column_20 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_20_link.id) FROM books_custom_column_20_link WHERE value=custom_column_20.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_20_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_20_link.value=custom_column_20.id AND bl.book=books_custom_column_20_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_20;
CREATE VIEW meta AS
                    SELECT id, title,
                        (SELECT sortconcat(bal.id, name) FROM books_authors_link AS bal JOIN authors ON(author = authors.id) WHERE book = books.id) authors,
                        (SELECT name FROM publishers WHERE publishers.id IN (SELECT publisher from books_publishers_link WHERE book=books.id)) publisher,
                        (SELECT rating FROM ratings WHERE ratings.id IN (SELECT rating from books_ratings_link WHERE book=books.id)) rating,
                        timestamp,
                        (SELECT MAX(uncompressed_size) FROM data WHERE book=books.id) size,
                        (SELECT concat(name) FROM tags WHERE tags.id IN (SELECT tag from books_tags_link WHERE book=books.id)) tags,
                        (SELECT text FROM comments WHERE book=books.id) comments,
                        (SELECT name FROM series WHERE series.id IN (SELECT series FROM books_series_link WHERE book=books.id)) series,
                        series_index,
                        sort,
                        author_sort,
                        (SELECT concat(format) FROM data WHERE data.book=books.id) formats,
                        path,
                        pubdate,
                        uuid
                    FROM books;
CREATE VIEW tag_browser_custom_column_21 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(id) FROM books_custom_column_21_link WHERE value=custom_column_21.id) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_21_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_21_link.value=custom_column_21.id and bl.book=books_custom_column_21_link.book and
                           r.id = bl.rating and r.rating <> 0) avg_rating,
                    value AS sort
                FROM custom_column_21;
CREATE VIEW tag_browser_filtered_custom_column_21 AS SELECT
                    id,
                    value,
                    (SELECT COUNT(books_custom_column_21_link.id) FROM books_custom_column_21_link WHERE value=custom_column_21.id AND
                    books_list_filter(book)) count,
                    (SELECT AVG(r.rating)
                     FROM books_custom_column_21_link,
                          books_ratings_link as bl,
                          ratings as r
                     WHERE books_custom_column_21_link.value=custom_column_21.id AND bl.book=books_custom_column_21_link.book AND
                           r.id = bl.rating AND r.rating <> 0 AND
                           books_list_filter(bl.book)) avg_rating,
                    value AS sort
                FROM custom_column_21;
CREATE INDEX authors_idx ON books (author_sort COLLATE NOCASE);
CREATE INDEX books_authors_link_aidx ON books_authors_link (author);
CREATE INDEX books_authors_link_bidx ON books_authors_link (book);
CREATE INDEX books_idx ON books (sort COLLATE NOCASE);
CREATE INDEX books_languages_link_aidx ON books_languages_link (lang_code);
CREATE INDEX books_languages_link_bidx ON books_languages_link (book);
CREATE INDEX books_publishers_link_aidx ON books_publishers_link (publisher);
CREATE INDEX books_publishers_link_bidx ON books_publishers_link (book);
CREATE INDEX books_ratings_link_aidx ON books_ratings_link (rating);
CREATE INDEX books_ratings_link_bidx ON books_ratings_link (book);
CREATE INDEX books_series_link_aidx ON books_series_link (series);
CREATE INDEX books_series_link_bidx ON books_series_link (book);
CREATE INDEX books_tags_link_aidx ON books_tags_link (tag);
CREATE INDEX books_tags_link_bidx ON books_tags_link (book);
CREATE INDEX comments_idx ON comments (book);
CREATE INDEX conversion_options_idx_a ON conversion_options (format COLLATE NOCASE);
CREATE INDEX conversion_options_idx_b ON conversion_options (book);
CREATE INDEX custom_columns_idx ON custom_columns (label);
CREATE INDEX data_idx ON data (book);
CREATE INDEX lrp_idx ON last_read_positions (book);
CREATE INDEX annot_idx ON annotations (book);
CREATE INDEX formats_idx ON data (format);
CREATE INDEX languages_idx ON languages (lang_code COLLATE NOCASE);
CREATE INDEX publishers_idx ON publishers (name COLLATE NOCASE);
CREATE INDEX series_idx ON series (name COLLATE NOCASE);
CREATE INDEX tags_idx ON tags (name COLLATE NOCASE);
CREATE INDEX custom_column_1_idx ON custom_column_1 (book);
CREATE INDEX custom_column_2_idx ON custom_column_2 (book);
CREATE INDEX custom_column_3_idx ON custom_column_3 (value );
CREATE INDEX books_custom_column_3_link_aidx ON books_custom_column_3_link (value);
CREATE INDEX books_custom_column_3_link_bidx ON books_custom_column_3_link (book);
CREATE INDEX custom_column_5_idx ON custom_column_5 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_5_link_aidx ON books_custom_column_5_link (value);
CREATE INDEX books_custom_column_5_link_bidx ON books_custom_column_5_link (book);
CREATE INDEX custom_column_7_idx ON custom_column_7 (book);
CREATE INDEX custom_column_8_idx ON custom_column_8 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_8_link_aidx ON books_custom_column_8_link (value);
CREATE INDEX books_custom_column_8_link_bidx ON books_custom_column_8_link (book);
CREATE INDEX custom_column_9_idx ON custom_column_9 (book);
CREATE INDEX custom_column_10_idx ON custom_column_10 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_10_link_aidx ON books_custom_column_10_link (value);
CREATE INDEX books_custom_column_10_link_bidx ON books_custom_column_10_link (book);
CREATE INDEX custom_column_11_idx ON custom_column_11 (book);
CREATE INDEX custom_column_12_idx ON custom_column_12 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_12_link_aidx ON books_custom_column_12_link (value);
CREATE INDEX books_custom_column_12_link_bidx ON books_custom_column_12_link (book);
CREATE INDEX custom_column_14_idx ON custom_column_14 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_14_link_aidx ON books_custom_column_14_link (value);
CREATE INDEX books_custom_column_14_link_bidx ON books_custom_column_14_link (book);
CREATE INDEX custom_column_16_idx ON custom_column_16 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_16_link_aidx ON books_custom_column_16_link (value);
CREATE INDEX books_custom_column_16_link_bidx ON books_custom_column_16_link (book);
CREATE INDEX custom_column_17_idx ON custom_column_17 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_17_link_aidx ON books_custom_column_17_link (value);
CREATE INDEX books_custom_column_17_link_bidx ON books_custom_column_17_link (book);
CREATE INDEX custom_column_18_idx ON custom_column_18 (book);
CREATE INDEX custom_column_20_idx ON custom_column_20 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_20_link_aidx ON books_custom_column_20_link (value);
CREATE INDEX books_custom_column_20_link_bidx ON books_custom_column_20_link (book);
CREATE INDEX books_pages_link_pidx ON books_pages_link (needs_scan);
CREATE INDEX custom_column_21_idx ON custom_column_21 (value COLLATE NOCASE);
CREATE INDEX books_custom_column_21_link_aidx ON books_custom_column_21_link (value);
CREATE INDEX books_custom_column_21_link_bidx ON books_custom_column_21_link (book);
CREATE INDEX custom_column_22_idx ON custom_column_22 (book);
CREATE TRIGGER annotations_fts_insert_trg AFTER INSERT ON annotations 
BEGIN
    INSERT INTO annotations_fts(rowid, searchable_text) VALUES (NEW.id, NEW.searchable_text);
    INSERT INTO annotations_fts_stemmed(rowid, searchable_text) VALUES (NEW.id, NEW.searchable_text);
END;
CREATE TRIGGER annotations_fts_delete_trg AFTER DELETE ON annotations 
BEGIN
    INSERT INTO annotations_fts(annotations_fts, rowid, searchable_text) VALUES('delete', OLD.id, OLD.searchable_text);
    INSERT INTO annotations_fts_stemmed(annotations_fts_stemmed, rowid, searchable_text) VALUES('delete', OLD.id, OLD.searchable_text);
END;
CREATE TRIGGER annotations_fts_update_trg AFTER UPDATE ON annotations 
BEGIN
    INSERT INTO annotations_fts(annotations_fts, rowid, searchable_text) VALUES('delete', OLD.id, OLD.searchable_text);
    INSERT INTO annotations_fts(rowid, searchable_text) VALUES (NEW.id, NEW.searchable_text);
    INSERT INTO annotations_fts_stemmed(annotations_fts_stemmed, rowid, searchable_text) VALUES('delete', OLD.id, OLD.searchable_text);
    INSERT INTO annotations_fts_stemmed(rowid, searchable_text) VALUES (NEW.id, NEW.searchable_text);
END;
CREATE TRIGGER books_delete_trg
            AFTER DELETE ON books
            BEGIN
                DELETE FROM books_authors_link WHERE book=OLD.id;
                DELETE FROM books_publishers_link WHERE book=OLD.id;
                DELETE FROM books_ratings_link WHERE book=OLD.id;
                DELETE FROM books_series_link WHERE book=OLD.id;
                DELETE FROM books_tags_link WHERE book=OLD.id;
                DELETE FROM books_languages_link WHERE book=OLD.id;
                DELETE FROM data WHERE book=OLD.id;
                DELETE FROM last_read_positions WHERE book=OLD.id;
                DELETE FROM annotations WHERE book=OLD.id;
                DELETE FROM comments WHERE book=OLD.id;
                DELETE FROM conversion_options WHERE book=OLD.id;
                DELETE FROM books_plugin_data WHERE book=OLD.id;
                DELETE FROM identifiers WHERE book=OLD.id;
        END;
CREATE TRIGGER fkc_comments_insert
        BEFORE INSERT ON comments
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_comments_update
        BEFORE UPDATE OF book ON comments
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_data_insert
        BEFORE INSERT ON data
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_data_update
        BEFORE UPDATE OF book ON data
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_lrp_insert
        BEFORE INSERT ON last_read_positions
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_lrp_update
        BEFORE UPDATE OF book ON last_read_positions
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_annot_insert
        BEFORE INSERT ON annotations
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_annot_update
        BEFORE UPDATE OF book ON annotations
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_delete_on_authors
        BEFORE DELETE ON authors
        BEGIN
            SELECT CASE
                WHEN (SELECT COUNT(id) FROM books_authors_link WHERE author=OLD.id) > 0
                THEN RAISE(ABORT, 'Foreign key violation: authors is still referenced')
            END;
        END;
CREATE TRIGGER fkc_delete_on_languages
        BEFORE DELETE ON languages
        BEGIN
            SELECT CASE
                WHEN (SELECT COUNT(id) FROM books_languages_link WHERE lang_code=OLD.id) > 0
                THEN RAISE(ABORT, 'Foreign key violation: language is still referenced')
            END;
        END;
CREATE TRIGGER fkc_delete_on_languages_link
        BEFORE INSERT ON books_languages_link
        BEGIN
          SELECT CASE
              WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: book not in books')
              WHEN (SELECT id from languages WHERE id=NEW.lang_code) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: lang_code not in languages')
          END;
        END;
CREATE TRIGGER fkc_delete_on_publishers
        BEFORE DELETE ON publishers
        BEGIN
            SELECT CASE
                WHEN (SELECT COUNT(id) FROM books_publishers_link WHERE publisher=OLD.id) > 0
                THEN RAISE(ABORT, 'Foreign key violation: publishers is still referenced')
            END;
        END;
CREATE TRIGGER fkc_delete_on_series
        BEFORE DELETE ON series
        BEGIN
            SELECT CASE
                WHEN (SELECT COUNT(id) FROM books_series_link WHERE series=OLD.id) > 0
                THEN RAISE(ABORT, 'Foreign key violation: series is still referenced')
            END;
        END;
CREATE TRIGGER fkc_delete_on_tags
        BEFORE DELETE ON tags
        BEGIN
            SELECT CASE
                WHEN (SELECT COUNT(id) FROM books_tags_link WHERE tag=OLD.id) > 0
                THEN RAISE(ABORT, 'Foreign key violation: tags is still referenced')
            END;
        END;
CREATE TRIGGER fkc_insert_books_authors_link
        BEFORE INSERT ON books_authors_link
        BEGIN
          SELECT CASE
              WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: book not in books')
              WHEN (SELECT id from authors WHERE id=NEW.author) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: author not in authors')
          END;
        END;
CREATE TRIGGER fkc_insert_books_publishers_link
        BEFORE INSERT ON books_publishers_link
        BEGIN
          SELECT CASE
              WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: book not in books')
              WHEN (SELECT id from publishers WHERE id=NEW.publisher) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: publisher not in publishers')
          END;
        END;
CREATE TRIGGER fkc_insert_books_ratings_link
        BEFORE INSERT ON books_ratings_link
        BEGIN
          SELECT CASE
              WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: book not in books')
              WHEN (SELECT id from ratings WHERE id=NEW.rating) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: rating not in ratings')
          END;
        END;
CREATE TRIGGER fkc_insert_books_series_link
        BEFORE INSERT ON books_series_link
        BEGIN
          SELECT CASE
              WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: book not in books')
              WHEN (SELECT id from series WHERE id=NEW.series) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: series not in series')
          END;
        END;
CREATE TRIGGER fkc_insert_books_tags_link
        BEFORE INSERT ON books_tags_link
        BEGIN
          SELECT CASE
              WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: book not in books')
              WHEN (SELECT id from tags WHERE id=NEW.tag) IS NULL
              THEN RAISE(ABORT, 'Foreign key violation: tag not in tags')
          END;
        END;
CREATE TRIGGER fkc_update_books_authors_link_a
        BEFORE UPDATE OF book ON books_authors_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_update_books_authors_link_b
        BEFORE UPDATE OF author ON books_authors_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from authors WHERE id=NEW.author) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: author not in authors')
            END;
        END;
CREATE TRIGGER fkc_update_books_languages_link_a
        BEFORE UPDATE OF book ON books_languages_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_update_books_languages_link_b
        BEFORE UPDATE OF lang_code ON books_languages_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from languages WHERE id=NEW.lang_code) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: lang_code not in languages')
            END;
        END;
CREATE TRIGGER fkc_update_books_publishers_link_a
        BEFORE UPDATE OF book ON books_publishers_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_update_books_publishers_link_b
        BEFORE UPDATE OF publisher ON books_publishers_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from publishers WHERE id=NEW.publisher) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: publisher not in publishers')
            END;
        END;
CREATE TRIGGER fkc_update_books_ratings_link_a
        BEFORE UPDATE OF book ON books_ratings_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_update_books_ratings_link_b
        BEFORE UPDATE OF rating ON books_ratings_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from ratings WHERE id=NEW.rating) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: rating not in ratings')
            END;
        END;
CREATE TRIGGER fkc_update_books_series_link_a
        BEFORE UPDATE OF book ON books_series_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_update_books_series_link_b
        BEFORE UPDATE OF series ON books_series_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from series WHERE id=NEW.series) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: series not in series')
            END;
        END;
CREATE TRIGGER fkc_update_books_tags_link_a
        BEFORE UPDATE OF book ON books_tags_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
            END;
        END;
CREATE TRIGGER fkc_update_books_tags_link_b
        BEFORE UPDATE OF tag ON books_tags_link
        BEGIN
            SELECT CASE
                WHEN (SELECT id from tags WHERE id=NEW.tag) IS NULL
                THEN RAISE(ABORT, 'Foreign key violation: tag not in tags')
            END;
        END;
CREATE TRIGGER fkc_insert_custom_column_1
                        BEFORE INSERT ON custom_column_1
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_custom_column_1
                        BEFORE UPDATE OF book ON custom_column_1
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_insert_custom_column_2
                        BEFORE INSERT ON custom_column_2
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_custom_column_2
                        BEFORE UPDATE OF book ON custom_column_2
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_3_link_a
                        BEFORE UPDATE OF book ON books_custom_column_3_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_3_link_b
                        BEFORE UPDATE OF author ON books_custom_column_3_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_3 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_3')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_3_link
                        BEFORE INSERT ON books_custom_column_3_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_3 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_3')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_3_link
                        AFTER DELETE ON custom_column_3
                        BEGIN
                            DELETE FROM books_custom_column_3_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_5_link_a
                        BEFORE UPDATE OF book ON books_custom_column_5_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_5_link_b
                        BEFORE UPDATE OF author ON books_custom_column_5_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_5 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_5')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_5_link
                        BEFORE INSERT ON books_custom_column_5_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_5 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_5')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_5_link
                        AFTER DELETE ON custom_column_5
                        BEGIN
                            DELETE FROM books_custom_column_5_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_insert_custom_column_7
                        BEFORE INSERT ON custom_column_7
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_custom_column_7
                        BEFORE UPDATE OF book ON custom_column_7
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_8_link_a
                        BEFORE UPDATE OF book ON books_custom_column_8_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_8_link_b
                        BEFORE UPDATE OF author ON books_custom_column_8_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_8 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_8')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_8_link
                        BEFORE INSERT ON books_custom_column_8_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_8 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_8')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_8_link
                        AFTER DELETE ON custom_column_8
                        BEGIN
                            DELETE FROM books_custom_column_8_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_insert_custom_column_9
                        BEFORE INSERT ON custom_column_9
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_custom_column_9
                        BEFORE UPDATE OF book ON custom_column_9
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_10_link_a
                        BEFORE UPDATE OF book ON books_custom_column_10_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_10_link_b
                        BEFORE UPDATE OF author ON books_custom_column_10_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_10 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_10')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_10_link
                        BEFORE INSERT ON books_custom_column_10_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_10 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_10')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_10_link
                        AFTER DELETE ON custom_column_10
                        BEGIN
                            DELETE FROM books_custom_column_10_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_insert_custom_column_11
                        BEFORE INSERT ON custom_column_11
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_custom_column_11
                        BEFORE UPDATE OF book ON custom_column_11
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_12_link_a
                        BEFORE UPDATE OF book ON books_custom_column_12_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_12_link_b
                        BEFORE UPDATE OF author ON books_custom_column_12_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_12 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_12')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_12_link
                        BEFORE INSERT ON books_custom_column_12_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_12 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_12')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_12_link
                        AFTER DELETE ON custom_column_12
                        BEGIN
                            DELETE FROM books_custom_column_12_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_14_link_a
                        BEFORE UPDATE OF book ON books_custom_column_14_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_14_link_b
                        BEFORE UPDATE OF author ON books_custom_column_14_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_14 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_14')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_14_link
                        BEFORE INSERT ON books_custom_column_14_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_14 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_14')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_14_link
                        AFTER DELETE ON custom_column_14
                        BEGIN
                            DELETE FROM books_custom_column_14_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_16_link_a
                        BEFORE UPDATE OF book ON books_custom_column_16_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_16_link_b
                        BEFORE UPDATE OF author ON books_custom_column_16_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_16 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_16')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_16_link
                        BEFORE INSERT ON books_custom_column_16_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_16 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_16')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_16_link
                        AFTER DELETE ON custom_column_16
                        BEGIN
                            DELETE FROM books_custom_column_16_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_17_link_a
                        BEFORE UPDATE OF book ON books_custom_column_17_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_17_link_b
                        BEFORE UPDATE OF author ON books_custom_column_17_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_17 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_17')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_17_link
                        BEFORE INSERT ON books_custom_column_17_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_17 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_17')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_17_link
                        AFTER DELETE ON custom_column_17
                        BEGIN
                            DELETE FROM books_custom_column_17_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_insert_custom_column_18
                        BEFORE INSERT ON custom_column_18
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_custom_column_18
                        BEFORE UPDATE OF book ON custom_column_18
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_20_link_a
                        BEFORE UPDATE OF book ON books_custom_column_20_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_20_link_b
                        BEFORE UPDATE OF author ON books_custom_column_20_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_20 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_20')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_20_link
                        BEFORE INSERT ON books_custom_column_20_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_20 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_20')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_20_link
                        AFTER DELETE ON custom_column_20
                        BEGIN
                            DELETE FROM books_custom_column_20_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER books_pages_link_create_trigger AFTER INSERT ON books FOR EACH ROW
            BEGIN
                INSERT INTO books_pages_link(book) VALUES(NEW.id);
            END;
CREATE TRIGGER fkc_update_books_custom_column_21_link_a
                        BEFORE UPDATE OF book ON books_custom_column_21_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_books_custom_column_21_link_b
                        BEFORE UPDATE OF author ON books_custom_column_21_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from custom_column_21 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_21')
                            END;
                        END;
CREATE TRIGGER fkc_insert_books_custom_column_21_link
                        BEFORE INSERT ON books_custom_column_21_link
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                                WHEN (SELECT id from custom_column_21 WHERE id=NEW.value) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: value not in custom_column_21')
                            END;
                        END;
CREATE TRIGGER fkc_delete_books_custom_column_21_link
                        AFTER DELETE ON custom_column_21
                        BEGIN
                            DELETE FROM books_custom_column_21_link WHERE value=OLD.id;
                        END;
CREATE TRIGGER fkc_insert_custom_column_22
                        BEFORE INSERT ON custom_column_22
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
CREATE TRIGGER fkc_update_custom_column_22
                        BEFORE UPDATE OF book ON custom_column_22
                        BEGIN
                            SELECT CASE
                                WHEN (SELECT id from books WHERE id=NEW.book) IS NULL
                                THEN RAISE(ABORT, 'Foreign key violation: book not in books')
                            END;
                        END;
