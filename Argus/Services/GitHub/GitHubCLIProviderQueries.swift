extension GitHubCLIProvider {
    static let reviewInboxQuery = """
    query ReviewInbox($after: String) {
      viewer {
        login
      }
      search(query: "is:pr is:open review-requested:@me", type: ISSUE, first: 100, after: $after) {
        nodes {
          ... on PullRequest {
            id
            number
            title
            state
            isDraft
            url
            updatedAt
            author { login }
            baseRefOid
            headRefOid
            repository { nameWithOwner }
            requestedReviewers(first: 100) {
              nodes {
                __typename
                ... on User { login }
                ... on Team { slug }
              }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    static let requestedReviewersQuery = """
    query PullRequestRequestedReviewers($id: ID!, $after: String) {
      node(id: $id) {
        ... on PullRequest {
          requestedReviewers(first: 100, after: $after) {
            nodes {
              __typename
              ... on User { login }
              ... on Team { slug }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """

    static let reviewDecisionQuery = """
    query ReviewDecision($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewDecision
        }
      }
    }
    """

    static let changedFileViewedStatesQuery = """
    query PullRequestChangedFileViewedStates($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          files(first: 100, after: $after) {
            nodes {
              path
              viewerViewedState
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """

    static let publishedReviewConversationsQuery = """
    query PublishedReviewConversations($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            nodes {
              id
              path
              line
              startLine
              diffSide
              startDiffSide
              isResolved
              isOutdated
              viewerCanResolve
              viewerCanUnresolve
              comments(first: 100) {
                nodes {
                  id
                  databaseId
                  body
                  createdAt
                  updatedAt
                  url
                  author { login }
                }
                pageInfo { hasNextPage endCursor }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """

    static let publishedReviewThreadCommentsQuery = """
    query PublishedReviewThreadComments($id: ID!, $after: String) {
      node(id: $id) {
        ... on PullRequestReviewThread {
          comments(first: 100, after: $after) {
            nodes {
              id
              databaseId
              body
              createdAt
              updatedAt
              url
              author { login }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """
}
