{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE TemplateHaskell  #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Text.BlogLiterately.Post
-- Copyright   :  (c) 2008-2010 Robert Greayer, 2012 Brent Yorgey
-- License     :  GPL (see LICENSE)
-- Maintainer  :  Brent Yorgey <byorgey@gmail.com>
--
-- Uploading posts to the server and fetching posts from the server.
--
-----------------------------------------------------------------------------

module Text.BlogLiterately.Post
    (
      mkPost, mkArray, postIt, getPostURL, findTitle
    ) where

import           Control.Lens                (at, makePrisms, to, traverse,
                                              (^.), (^..), (^?), _Just, _head)
import           Data.Char                   (toLower)
import           Data.Function               (on)
import           Data.List                   (isInfixOf)
import qualified Data.Map                    as M

import           Network.XmlRpc.Client       (remote)
import           Network.XmlRpc.Internals    (Value (..), XmlRpcType, toValue)

import           Text.BlogLiterately.Options

{-
The metaWeblog API defines `newPost` and `editPost` procedures that
look like:

    [other]
    metaWeblog.newPost (blogid, username, password, struct, publish)
        returns string
    metaWeblog.editPost (postid, username, password, struct, publish)
        returns true

For WordPress blogs, the `blogid` is ignored.  The user name and
password are simply strings, and `publish` is a flag indicating
whether to load the post as a draft, or to make it public immediately.
The `postid` is an identifier string which is assigned when you
initially create a post. The interesting bit is the `struct` field,
which is an XML-RPC structure defining the post along with some
meta-data, like the title.  I want be able to provide the post body, a
title, and lists of categories and tags.  For the body and title, we
could just let HaXR convert the values automatically into the XML-RPC
`Value` type, since they all have the same Haskell type (`String`) and
thus can be put into a list.  But the categories and tags are lists of
strings, so we need to explicitly convert everything to a `Value`,
then combine:
-}

-- | Prepare a post for uploading by creating something of the proper
--   form to be an argument to an XML-RPC call.
mkPost :: String    -- ^ Post title
       -> String    -- ^ Post content
       -> [String]  -- ^ List of categories
       -> [String]  -- ^ List of tags
       -> Bool      -- ^ @True@ = page, @False@ = post
       -> [(String, Value)]
mkPost title_ text_ categories_ tags_ page_ =
       mkArray "categories" categories_
    ++ mkArray "mt_keywords" tags_
    ++ [ ("title", toValue title_)
       , ("description", toValue text_)
       ]
    ++ [ ("post_type", toValue "page") | page_ ]

-- | Given a name and a list of values, create a named \"array\" field
--   suitable for inclusion in an XML-RPC struct.
mkArray :: XmlRpcType [a] => String -> [a] -> [(String, Value)]
mkArray _    []     = []
mkArray name values = [(name, toValue values)]

{-
The HaXR library exports a function for invoking XML-RPC procedures:

    [haskell]
    remote :: Remote a =>
        String -- ^ Server URL. May contain username and password on
               --   the format username:password\@ before the hostname.
           -> String -- ^ Remote method name.
           -> a      -- ^ Any function
         -- @(XmlRpcType t1, ..., XmlRpcType tn, XmlRpcType r) =>
                     -- t1 -> ... -> tn -> IO r@

The function requires an URL and a method name, and returns a function
of type `Remote a => a`.  Based on the instances defined for `Remote`,
any function with zero or more parameters in the class `XmlRpcType`
and a return type of `XmlRpcType r => IO r` will work, which means you
can simply 'feed' `remote` additional arguments as required by the
remote procedure, and as long as you make the call in an IO context,
it will typecheck.  `postIt` calls `metaWeblog.newPost` or
`metaWeblog.editPost` (or simply prints the HTML to stdout) as
appropriate:
-}

makePrisms ''Value

-- | Get the URL for a given post.
getPostURL :: String -> String -> String -> String -> IO (Maybe String)
getPostURL url pid usr pwd = do
  v <- remote url "metaWeblog.getPost" pid usr pwd
  return (v ^? _ValueStruct . to M.fromList . at "link" . traverse . _ValueString)

-- | Look at the last n posts and find the most recent whose title
--   contains the search term (case insensitive); return its permalink
--   URL.
findTitle :: Int -> String -> String -> String -> String -> IO (Maybe String)
findTitle numPrev url search usr pwd = do
  res <- remote url "metaWeblog.getRecentPosts" (0::Int) usr pwd numPrev
  let matches s = (isInfixOf `on` map toLower) search s
      posts  = res ^.. _ValueArray . traverse . _ValueStruct . to M.fromList
      posts' = filter (\p -> maybe False matches (p ^? at "title" . _Just . _ValueString)) posts
  return (posts' ^? _head . at "link" . _Just . _ValueString)

-- | Given a configuration and a formatted post, upload it to the server.
postIt :: BlogLiterately -> String -> IO ()
postIt bl html =
  case (bl^.blog, bl^.htmlOnly) of
    (Nothing  , _         ) -> putStr html
    (_        , Just True ) -> putStr html
    (Just url , _         ) -> do
      let pwd = password' bl
      case bl^.postid of
        Nothing  -> do
          pid <- remote url "metaWeblog.newPost"
                   (blogid' bl)
                   (user' bl)
                   pwd
                   post
                   (publish' bl)
          putStrLn $ "Post ID: " ++ pid
          getPostURL url pid (user' bl) pwd >>= maybe (return ()) putStrLn
        Just pid -> do
          success <- remote url "metaWeblog.editPost" pid
                       (user' bl)
                       pwd
                       post
                       (publish' bl)
          case success of
            True  -> getPostURL url pid (user' bl) pwd >>= maybe (return ()) putStrLn
            False -> putStrLn "Update failed!"
  where
    post = mkPost
             (title' bl)
             html (bl^.categories) (bl^.tags)
             (page' bl)
