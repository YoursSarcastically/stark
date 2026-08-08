#!/usr/bin/env python3
"""
Generate the Stark fine-tuning dataset (fully synthetic, no customer data).

Stark is trained to map a ONE-WORD system tag + raw clipboard text to the
rewritten text and nothing else (no preamble, no quotes, no commentary).
Short prompts + short outputs = minimal prompt-processing latency.

Presets / system tags:
  polish   - fix grammar, clarity, and flow; keep meaning and tone
  concise  - shorten aggressively; keep meaning
  formal   - professional tone
  friendly - warm, casual tone
  typos    - fix spelling/typos ONLY; never rephrase
  bullets  - reformat into a markdown bullet list
  prompt   - sharpen a vague LLM prompt into a precise one
  expand   - lengthen a terse note into a fuller message; keep meaning and tone

Writes data/train.jsonl and data/valid.jsonl in mlx-lm chat format.
"""
import json
import os
import random
import re

random.seed(7)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data")

# ---------------------------------------------------------------------------
# polish — fix grammar/clarity/flow, keep meaning and register
# ---------------------------------------------------------------------------
POLISH = [
    ("me and the team was thinking we should push the release to next friday because their's still to many open bugs",
     "The team and I were thinking we should push the release to next Friday, because there are still too many open bugs."),
    ("this document explain how to setup the local environment for new developers joining to the project",
     "This document explains how to set up the local environment for new developers joining the project."),
    ("i tested the fix on staging and it seem to working fine now, will deploy tommorow morning if no one have objections",
     "I tested the fix on staging and it seems to be working fine now. I'll deploy tomorrow morning if no one has objections."),
    ("The meeting what we had yesterday it was very productive, we decided many things about the roadmap for next quarter.",
     "Yesterday's meeting was very productive; we made several decisions about next quarter's roadmap."),
    ("sorry for late reply, i was in vacations last week. answering your questions below",
     "Sorry for the late reply — I was on vacation last week. I've answered your questions below."),
    ("the app crashes sometime when user click save button two times fastly",
     "The app sometimes crashes when the user clicks the save button twice in quick succession."),
    ("Please find attached the report which contains all datas from the survey we runned in june.",
     "Please find attached the report containing all the data from the survey we ran in June."),
    ("we should of caught this bug in review, the null check were missing since two releases",
     "We should have caught this bug in review — the null check has been missing for two releases."),
    ("him and me will handle the migration this weekend so nobody else don't need to be on call",
     "He and I will handle the migration this weekend, so nobody else needs to be on call."),
    ("This feature allow users to exporting their data in csv format whenever they wants.",
     "This feature allows users to export their data in CSV format whenever they want."),
    ("There is many reasons why the tests is failing, but the mainly one is that the database fixture don't get reset between runs.",
     "There are many reasons why the tests are failing, but the main one is that the database fixture doesn't get reset between runs."),
    ("i think the design look good overall but the spacing between the cards feel a bit too tight on mobile screens",
     "I think the design looks good overall, but the spacing between the cards feels a bit too tight on mobile screens."),
    ("Each of the servers have their own config file, which make it hard to keeping them in sync.",
     "Each of the servers has its own config file, which makes it hard to keep them in sync."),
    ("after we shipped the new onboarding flow signups increased with 20% compared than last month",
     "After we shipped the new onboarding flow, signups increased by 20% compared to last month."),
    ("can you review my PR when you gets a chance? its the one what fixes the login redirect loop",
     "Can you review my PR when you get a chance? It's the one that fixes the login redirect loop."),
    ("The reason of the outage was because the certificate expired and no one didn't get the renewal alert.",
     "The outage happened because the certificate expired and no one received the renewal alert."),
    ("less people showed up to the webinar then we expected, probably because of it was scheduled too early",
     "Fewer people showed up to the webinar than we expected, probably because it was scheduled too early."),
    ("hey quick update — the vendor finally send us the API keys so we can starting the integration work from monday",
     "Hey, quick update — the vendor finally sent us the API keys, so we can start the integration work on Monday."),
    ("Our teams goal for this sprint are reducing the page load time and fix the top five crash reports.",
     "Our team's goals for this sprint are to reduce the page load time and fix the top five crash reports."),
    ("if the user don't verify there email in 24 hours the account get deleted automatic",
     "If the user doesn't verify their email within 24 hours, the account is deleted automatically."),
    ("I have went through the feedbacks and most of it are about the search being slow and results not relevant.",
     "I've gone through the feedback, and most of it is about the search being slow and the results not being relevant."),
    ("the new intern is doing very good, she already fixed three bugs and wrote documentations for the billing module",
     "The new intern is doing very well — she has already fixed three bugs and written documentation for the billing module."),
    ("between you and I, the deadline don't seem realistic unless we cutting the reporting feature from scope",
     "Between you and me, the deadline doesn't seem realistic unless we cut the reporting feature from scope."),
    ("We was planning to migrate the database this week however the backup script are still not tested proper.",
     "We were planning to migrate the database this week; however, the backup script still hasn't been properly tested."),
]

POLISH_NOOP = [
    "The deployment finished at 3 p.m. and all health checks are passing.",
    "Thanks for the quick turnaround — the fix works perfectly on my end.",
    "Our next planning meeting is on Thursday at 10 a.m. in the main conference room.",
]

# ---------------------------------------------------------------------------
# concise — cut words, keep meaning
# ---------------------------------------------------------------------------
CONCISE = [
    ("I just wanted to reach out and let you know that we have made the decision to go ahead and postpone the launch until such time as the remaining issues have been fully resolved.",
     "We've decided to postpone the launch until the remaining issues are resolved."),
    ("In the event that you are unable to attend the meeting, it would be greatly appreciated if you could let us know in advance so that we can make the necessary arrangements.",
     "If you can't attend the meeting, please let us know in advance."),
    ("At this point in time we are currently in the process of evaluating a number of different options with regard to the choice of database technology for the new project.",
     "We're currently evaluating database options for the new project."),
    ("Due to the fact that the server was experiencing an unusually high volume of traffic, the response times for all of the API endpoints were significantly slower than they normally would be.",
     "High server traffic significantly slowed all API response times."),
    ("It is important to note that each and every one of the configuration files needs to be updated before the deployment process can be started.",
     "Every configuration file must be updated before deployment."),
    ("I am writing this email to follow up on the conversation that we had last week regarding the possibility of extending the contract for an additional period of twelve months.",
     "I'm following up on last week's conversation about extending the contract by twelve months."),
    ("The purpose of this document is to provide a detailed explanation of the steps that are required in order to successfully set up the development environment on a new machine.",
     "This document explains how to set up the development environment on a new machine."),
    ("We came to the conclusion that the best course of action would be to completely rewrite the module rather than attempting to patch the existing implementation over and over again.",
     "We concluded it's best to rewrite the module rather than keep patching it."),
    ("There is a possibility that we may need to make some adjustments to the timeline depending on whether or not the client provides their feedback by the end of this week.",
     "We may need to adjust the timeline if the client doesn't send feedback by Friday."),
    ("Please be advised that the system will be temporarily unavailable for a short period of time on Saturday morning owing to the fact that we will be performing scheduled maintenance.",
     "The system will be briefly unavailable Saturday morning for scheduled maintenance."),
    ("As far as the onboarding flow is concerned, my personal opinion on the matter is that it contains too many steps and that some of them could probably be combined together or removed entirely.",
     "The onboarding flow has too many steps; some could be combined or removed."),
    ("What I'm trying to say is that, basically, if we don't start the hiring process now, there's a real chance we won't have anyone in place by the time the project actually kicks off in March.",
     "If we don't start hiring now, we may have no one in place when the project starts in March."),
    ("The report that was generated by the analytics team shows that there has been a noticeable increase in the number of users who abandon their carts during the checkout process.",
     "The analytics report shows a noticeable increase in checkout cart abandonment."),
    ("In order to be able to reproduce the bug, it is first necessary to log in with an admin account and then navigate to the settings page before clicking on the export button.",
     "To reproduce the bug: log in as admin, open the settings page, and click export."),
    ("I would like to take this opportunity to thank each and every member of the team for all of the hard work and effort that they have put in over the course of the last few months.",
     "Thank you all for your hard work over the last few months."),
    ("It has come to our attention that a number of customers have been experiencing difficulties when attempting to reset their passwords using the link provided in the email.",
     "Several customers can't reset their passwords via the email link."),
    ("Just as a heads up, there is a chance that I might be running a little bit late to the standup tomorrow morning because I have a doctor's appointment that might go over.",
     "Heads up: I might be late to standup tomorrow due to a doctor's appointment."),
    ("Moving forward, it would be beneficial for us to establish a regular cadence of check-in meetings so that we can ensure that everyone remains aligned on the goals of the project.",
     "Let's set up regular check-ins to keep everyone aligned on project goals."),
    ("The new caching layer that was introduced in the most recent release has resulted in a substantial improvement in terms of the overall performance of the application.",
     "The new caching layer substantially improved application performance."),
    ("Before making any changes to the production database, it is absolutely essential that you first create a complete backup of all of the existing data.",
     "Always back up the production database before making changes."),
    ("We are reaching out to inform you that your subscription is due for renewal at the end of the current billing period, and no action is required on your part if you wish to continue.",
     "Your subscription renews at the end of this billing period; no action is needed to continue."),
    ("To whom it may concern, I am writing to formally request access to the shared analytics dashboard for the purposes of completing my quarterly reporting responsibilities.",
     "I'd like to request access to the shared analytics dashboard for quarterly reporting."),
]

CONCISE_NOOP = [
    "Ship it.",
    "Meeting moved to 3 p.m. Same room.",
]

# ---------------------------------------------------------------------------
# formal — professional tone
# ---------------------------------------------------------------------------
FORMAL = [
    ("hey can u send me the invoice from last month? need it for the finance guys asap",
     "Hello, could you please send me last month's invoice? The finance team needs it urgently."),
    ("sorry but that deadline is nuts, no way we can get it done by friday",
     "Unfortunately, that deadline is not feasible; we will not be able to complete the work by Friday."),
    ("yeah the demo went great, they seemed super into it, think we'll close this one",
     "The demo went very well. The client was highly engaged, and I am confident we will close this deal."),
    ("my bad, totally forgot to loop you in on that email thread. adding you now",
     "My apologies — I neglected to include you on that email thread. I am adding you now."),
    ("we're gonna need more people on this or it's not happening",
     "We will require additional staffing on this project; otherwise, it cannot be delivered."),
    ("thx for waiting! the thing you asked about is fixed now, lemme know if it acts up again",
     "Thank you for your patience. The issue you reported has been resolved; please let us know if it recurs."),
    ("quick q — who's the right person to talk to about getting a refund sorted for this customer?",
     "Could you please direct me to the appropriate person to arrange a refund for this customer?"),
    ("heads up, the api is gonna be down saturday morning for maintenance stuff",
     "Please note that the API will be unavailable on Saturday morning due to scheduled maintenance."),
    ("nope, we can't do a discount that big. best we can do is 10%",
     "I am afraid we are unable to offer a discount of that size; the most we can offer is 10%."),
    ("the numbers look off in this report, can someone double check before it goes to the client?",
     "The figures in this report appear inconsistent. Could someone please verify them before it is sent to the client?"),
    ("hey team, awesome job this sprint, we crushed every single ticket",
     "Team, excellent work this sprint — we completed every ticket on the board."),
    ("i'm out sick today, will catch up on everything tomorrow",
     "I am unwell and will be out of office today. I will catch up on all outstanding items tomorrow."),
    ("can we push our 1:1 to thursday? something came up",
     "Would it be possible to reschedule our one-on-one to Thursday? A conflict has come up."),
    ("just fyi the client keeps asking about the mobile app timeline and honestly idk what to tell them",
     "For your awareness, the client has repeatedly asked about the mobile app timeline, and I do not yet have a definitive answer to give them."),
    ("we messed up the billing for a bunch of accounts last night. fixing it now, should be sorted by eod",
     "Last night we identified a billing error affecting a number of accounts. We are correcting it now and expect it to be fully resolved by end of day."),
    ("don't use the old dashboard anymore, it's dead. new one's linked in the wiki",
     "Please discontinue use of the old dashboard, as it has been decommissioned. The new dashboard is linked in the wiki."),
    ("got your message, will get back to you tomorrow with the full breakdown",
     "Thank you for your message. I will respond tomorrow with the full breakdown."),
    ("the candidate was fine i guess but didn't really blow me away, on the fence about moving forward",
     "The candidate was competent but did not stand out. I am undecided about advancing them to the next stage."),
    ("look, we've been waiting on this payment for two months now. need it settled this week or we pause the work",
     "Our invoice has now been outstanding for two months. We must ask that it be settled this week; otherwise, we will need to pause work on the engagement."),
    ("welcome aboard!! so stoked to have you on the team, ping me if you need anything",
     "Welcome to the team — we are delighted to have you join us. Please do not hesitate to reach out if you need anything."),
]

# ---------------------------------------------------------------------------
# friendly — warm, casual tone
# ---------------------------------------------------------------------------
FRIENDLY = [
    ("Per my previous email, the deliverables were due on Monday. Please advise on the current status.",
     "Hey, just checking in on the deliverables from Monday — how are they coming along?"),
    ("Your request has been received and will be processed within 3-5 business days.",
     "Got your request! We'll have it sorted within 3–5 business days."),
    ("We regret to inform you that the feature you requested is not on our current roadmap.",
     "Thanks so much for the suggestion! It's not on our roadmap just yet, but we've noted it down for future planning."),
    ("Attendance at the all-hands meeting on Friday is mandatory for all employees.",
     "Don't forget — Friday's all-hands is a big one, so we'd love to see everyone there!"),
    ("The document you submitted contains several errors that must be corrected before approval.",
     "Thanks for sending the doc over! There are a few small things to fix before we can approve it — happy to walk you through them."),
    ("I am following up regarding the invoice that remains unpaid. Immediate payment is expected.",
     "Hi! Just a friendly nudge about the invoice — could you take a look when you get a chance?"),
    ("It has come to my attention that you have not completed the onboarding modules.",
     "Hey! Noticed you haven't gotten to the onboarding modules yet — no stress, just give me a shout if you're stuck on anything."),
    ("The meeting is canceled. A new date will be communicated in due course.",
     "Heads up — today's meeting is off! We'll find a new time soon and let you know."),
    ("Employees must submit their expense reports no later than the last day of the month.",
     "Quick reminder: get your expense reports in by the end of the month so we can pay you back faster!"),
    ("Your account has been successfully upgraded to the premium tier.",
     "Great news — you're all upgraded to premium! Enjoy the new features."),
    ("I require the updated figures before the end of the day in order to finalize the report.",
     "Hey, could you send over the updated figures sometime today? I need them to wrap up the report — thanks a ton!"),
    ("This is a reminder that your trial period expires in three days.",
     "Just a heads up — your trial wraps up in three days! Hope you've been enjoying it."),
    ("The candidate should be informed that we will not be proceeding with their application.",
     "Let's let the candidate know we won't be moving forward this time — and thank them properly for their time, they were lovely to talk to."),
    ("Please ensure the conference room is left in a clean state after use.",
     "Tiny favor — let's leave the conference room nice and tidy for the next folks!"),
    ("I acknowledge receipt of your email and will respond in detail at a later time.",
     "Got it, thanks! I'll get back to you with a proper reply soon."),
    ("The office will be closed on Monday in observance of the public holiday.",
     "Enjoy the long weekend, everyone — the office is closed Monday for the holiday!"),
    ("We have processed your refund. Allow 5-7 business days for the funds to appear.",
     "Your refund is on its way! It should land in your account within 5–7 business days."),
    ("Team members are encouraged to provide feedback on the new process via the form.",
     "We'd genuinely love to hear what you think of the new process — drop your thoughts in the form when you have a sec!"),
    ("Due to resource constraints, your ticket has been assigned a lower priority.",
     "Thanks for your patience on this one! We've got a bit of a queue right now, so it might take a little longer than usual — but it's on our radar, promise."),
    ("Congratulations on the completion of your first month at the company.",
     "Happy one-month anniversary! 🎉 So glad you're here — hope it's been a great ride so far."),
]

# ---------------------------------------------------------------------------
# typos — clean sentences that get programmatically corrupted.
# The model must fix spelling ONLY, never rephrase.
# ---------------------------------------------------------------------------
TYPO_CLEAN = [
    "I definitely think we should schedule the review for tomorrow because the environment is finally stable.",
    "The government report separates the data into three categories, which is really convenient for our analysis.",
    "Unfortunately the maintenance window occurred immediately after the deployment, so we couldn't verify the fix.",
    "She received the calendar invite but couldn't attend because of a conflicting appointment.",
    "It's necessary to accommodate the new requirements before the business review next week.",
    "My colleague believes the threshold for alerts is too low, and I'm surprised nobody noticed earlier.",
    "We finally have a guarantee from the vendor that the foreign exchange rates will update every minute.",
    "I'm grateful for your patience — the experience with the new dashboard should be noticeably better now.",
    "Please remember to update your password before the deadline, otherwise your account will be locked.",
    "The restaurant near the office is probably the best place for the team lunch on Friday.",
    "Their new feature truly improves the checkout flow, and it's already reducing cart abandonment.",
    "I noticed a weird bug where the settings page doesn't load until you refresh it twice.",
    "We should probably document this process so the knowledge doesn't live in one person's head.",
    "The existence of two config files for the same service is embarrassing and we should fix it.",
    "Everything happened so fast that we didn't have time to write up the incident until today.",
    "You're going to need admin access before you can change anything in the billing settings.",
    "The survey results are in, and it's clear that customers want faster response times.",
    "I can't believe the demo went so smoothly — there wasn't a single crash the whole hour.",
    "Don't forget to back up the database before you run the migration script tonight.",
    "There are too many meetings on Thursday, so let's move the retrospective to Friday morning.",
    "The interest in the beta program has been higher than we expected, which is a nice surprise.",
    "He said the new office is quieter than the old one, which makes it easier to concentrate.",
    "We need to separate the staging and production credentials immediately.",
    "I'll send the summary tomorrow morning once I've had a chance to review the numbers.",
    "The success of this launch depends on whether the marketing campaign starts on time.",
    "Please check whether the license renewal happened, because the invoice hasn't arrived yet.",
    "Its battery lasts about ten hours, which is more than enough for a full workday.",
    "The committee finally approved the budget, so we can start hiring next month.",
    "I think there's an opportunity to simplify the onboarding flow quite a bit.",
    "Your presentation yesterday was excellent, and several people mentioned it afterwards.",
    "The library upgrade broke two of our integration tests, but the fixes were straightforward.",
    "We're planning to migrate the remaining services to the new cluster over the weekend.",
    "Nobody remembered to renew the certificate, which is why the site went down at midnight.",
    "The tutorial explains how to configure the webhook, but it skips the authentication step.",
    "A separate ticket has been created to track the performance regression on the search page.",
    "It's important that everyone acknowledges the new security policy by the end of the week.",
    "The client finally signed the contract, so the project officially begins on Monday.",
    "Occasionally the sync job fails silently, and we only notice when the numbers look wrong.",
]

TYPO_NOOP = [
    "The report is ready and waiting in the shared folder.",
    "All tests passed on the second run.",
    "Lunch is at noon in the courtyard.",
]

# Word-level misspellings applied to TYPO_CLEAN inputs.
MISSPELL = {
    "definitely": "definately", "schedule": "scedule", "environment": "enviroment",
    "government": "goverment", "separates": "seperates", "separate": "seperate",
    "really": "realy", "unfortunately": "unfortunatly", "maintenance": "maintainance",
    "occurred": "occured", "immediately": "immediatly", "received": "recieved",
    "calendar": "calender", "necessary": "neccessary", "accommodate": "accomodate",
    "business": "buisness", "colleague": "collegue", "believes": "beleives",
    "threshold": "treshold", "surprised": "suprised", "guarantee": "gaurantee",
    "foreign": "foriegn", "minute": "minuet", "grateful": "greatful",
    "experience": "experiance", "noticeably": "noticably", "remember": "remeber",
    "restaurant": "restaurent", "truly": "truely", "weird": "wierd",
    "probably": "probaly", "knowledge": "knowlege", "existence": "existance",
    "embarrassing": "embarassing", "happened": "happend", "surprise": "suprise",
    "quieter": "quiter", "concentrate": "concentate", "tomorrow": "tommorow",
    "success": "sucess", "whether": "wether", "license": "lisence",
    "committee": "commitee", "approved": "aproved", "opportunity": "oportunity",
    "excellent": "excelent", "mentioned": "mentionned", "straightforward": "straightfoward",
    "migrate": "migrate", "remembered": "remebered", "certificate": "certficate",
    "tutorial": "tutoral", "authentication": "authentification", "performance": "performence",
    "important": "importent", "acknowledges": "acknowleges", "officially": "offically",
    "occasionally": "ocassionally", "silently": "silenty", "because": "becuase",
    "which": "wich", "finally": "finaly", "until": "untill",
}

# Homophone / apostrophe corruptions (word-boundary, case-sensitive forms).
GRAMMAR_SWAPS = [
    (r"\bIt's\b", "Its"), (r"\bit's\b", "its"), (r"\bIts\b", "It's"),
    (r"\bYou're\b", "Your"), (r"\byou're\b", "your"),
    (r"\bTheir\b", "There"), (r"\btheir\b", "there"),
    (r"\bThere are\b", "Their are"), (r"\bthere's\b", "theres"),
    (r"\bdon't\b", "dont"), (r"\bDon't\b", "Dont"),
    (r"\bcan't\b", "cant"), (r"\bcouldn't\b", "couldnt"),
    (r"\bdoesn't\b", "doesnt"), (r"\bdidn't\b", "didnt"),
    (r"\bwasn't\b", "wasnt"), (r"\bhasn't\b", "hasnt"),
    (r"\bwe're\b", "were"), (r"\bWe're\b", "Were"),
    (r"\bI'm\b", "im"), (r"\bI'll\b", "ill"), (r"\bI've\b", "ive"),
    (r"\btoo\b", "to"), (r"\bthan\b", "then"),
]


def corrupt_chars(word):
    """One random character-level typo in a word (swap/drop/double)."""
    if len(word) < 4 or not word.isalpha():
        return word
    op = random.choice(["swap", "drop", "double"])
    i = random.randrange(1, len(word) - 1)
    if op == "swap":
        return word[:i] + word[i + 1] + word[i] + word[i + 2:]
    if op == "drop":
        return word[:i] + word[i + 1:]
    return word[:i] + word[i] + word[i:]


def corrupt(sentence):
    """Apply 2-4 corruptions; return corrupted text (target = original)."""
    s = sentence
    applied = 0
    # word-level misspellings first (highest signal)
    for good, bad in MISSPELL.items():
        if applied >= 2:
            break
        pat = r"\b" + re.escape(good) + r"\b"
        if re.search(pat, s):
            s = re.sub(pat, bad, s, count=1)
            applied += 1
    # one grammar/apostrophe swap if available
    swaps = [(p, r) for p, r in GRAMMAR_SWAPS if re.search(p, s)]
    if swaps and random.random() < 0.8:
        p, r = random.choice(swaps)
        s = re.sub(p, r, s, count=1)
        applied += 1
    # char-level noise on 1-2 random long words
    words = s.split(" ")
    idxs = [i for i, w in enumerate(words) if len(w) >= 5 and w.isalpha()]
    random.shuffle(idxs)
    for i in idxs[: max(1, 3 - applied)]:
        words[i] = corrupt_chars(words[i])
    s = " ".join(words)
    return s if s != sentence else corrupt_chars_fallback(sentence)


def corrupt_chars_fallback(sentence):
    words = sentence.split(" ")
    for i, w in enumerate(words):
        if len(w) >= 5 and w.isalpha():
            words[i] = corrupt_chars(w)
            break
    return " ".join(words)


# ---------------------------------------------------------------------------
# bullets — prose to markdown bullet list
# ---------------------------------------------------------------------------
BULLETS = [
    ("The release includes three main changes: we upgraded the database driver, we fixed the memory leak in the export job, and we added dark mode support to the settings page.",
     "- Upgraded the database driver\n- Fixed the memory leak in the export job\n- Added dark mode support to the settings page"),
    ("Before the demo tomorrow, please make sure the staging environment is reset, the sample data is loaded, the presenter laptop is charged, and someone has tested the projector connection.",
     "- Reset the staging environment\n- Load the sample data\n- Charge the presenter laptop\n- Test the projector connection"),
    ("During the retrospective the team raised a few concerns. Code reviews are taking too long, sometimes more than two days. The staging environment is flaky and blocks QA. And we keep starting new work before finishing what's already in progress.",
     "- Code reviews are taking too long (sometimes over two days)\n- The staging environment is flaky and blocks QA\n- New work keeps starting before in-progress work is finished"),
    ("To set up the project you need to clone the repository, install the dependencies with npm install, copy the example env file to .env, and finally run npm run dev to start the local server.",
     "- Clone the repository\n- Install dependencies: `npm install`\n- Copy the example env file to `.env`\n- Start the local server: `npm run dev`"),
    ("The candidate has six years of backend experience, mostly with Python and Go. She led the payments team at her last company. She's looking for a role with more architectural ownership, and her notice period is one month.",
     "- Six years of backend experience, mostly Python and Go\n- Led the payments team at her last company\n- Looking for a role with more architectural ownership\n- Notice period: one month"),
    ("Key takeaways from the customer call: they love the new dashboard but find the export feature confusing, they want SSO before rolling out to the whole org, and they asked about volume pricing for 500+ seats.",
     "- Love the new dashboard, but find the export feature confusing\n- Want SSO before rolling out to the whole org\n- Asked about volume pricing for 500+ seats"),
    ("This quarter we're focusing on reducing churn among small business customers, launching the mobile app in beta, and cutting infrastructure costs by about 15 percent.",
     "- Reduce churn among small business customers\n- Launch the mobile app in beta\n- Cut infrastructure costs by ~15%"),
    ("The incident started at 2:14 AM when the primary database ran out of disk space. Alerts fired but the on-call engineer's phone was on silent. Service was restored at 3:40 AM after failing over to the replica. Total downtime was 86 minutes.",
     "- 2:14 AM — primary database ran out of disk space; incident began\n- Alerts fired, but the on-call engineer's phone was on silent\n- 3:40 AM — service restored after failover to the replica\n- Total downtime: 86 minutes"),
    ("For the offsite we still need to book the venue, confirm the headcount with each team lead, arrange transport from the office, and decide whether the second day is workshops or free time.",
     "- Book the venue\n- Confirm headcount with each team lead\n- Arrange transport from the office\n- Decide: workshops or free time for day two"),
    ("The new pricing has three tiers. Starter is $19 a month and includes up to five users. Growth is $49 a month with up to twenty users and priority support. Enterprise is custom priced with unlimited users, SSO, and a dedicated account manager.",
     "- **Starter** — $19/month, up to 5 users\n- **Growth** — $49/month, up to 20 users, priority support\n- **Enterprise** — custom pricing, unlimited users, SSO, dedicated account manager"),
    ("A few things came out of the security audit. We should rotate all API keys older than a year. Two S3 buckets are publicly readable and need locking down. MFA still isn't enforced for contractor accounts. And the dependency scanner found four high-severity vulnerabilities.",
     "- Rotate all API keys older than a year\n- Lock down two publicly readable S3 buckets\n- Enforce MFA for contractor accounts\n- Fix four high-severity vulnerabilities found by the dependency scanner"),
    ("My plan for today is to finish the code review for the auth PR, write the migration script for the user table, pair with Sam on the flaky test, and prep slides for Thursday's demo.",
     "- Finish code review for the auth PR\n- Write the migration script for the user table\n- Pair with Sam on the flaky test\n- Prep slides for Thursday's demo"),
    ("The app needs the following permissions: camera access for scanning receipts, notification access for payment reminders, and biometric access for securing the login.",
     "- Camera — scanning receipts\n- Notifications — payment reminders\n- Biometrics — securing login"),
    ("We compared the two vendors. Vendor A is cheaper and has better documentation but their support is email-only. Vendor B costs about 30% more but offers 24/7 phone support and an SLA with 99.9% uptime.",
     "- **Vendor A** — cheaper, better documentation, but email-only support\n- **Vendor B** — ~30% more expensive, 24/7 phone support, 99.9% uptime SLA"),
    ("Onboarding feedback from the last three hires: the laptop arrived late in two cases, access requests took nearly a week, the buddy system worked really well, and the documentation for local setup is out of date.",
     "- Laptop arrived late (two of three hires)\n- Access requests took nearly a week\n- Buddy system worked really well\n- Local setup documentation is out of date"),
    ("Remember that the API rate limit is 100 requests per minute, responses are cached for 60 seconds, authentication uses bearer tokens that expire after 24 hours, and all timestamps are in UTC.",
     "- Rate limit: 100 requests/minute\n- Responses cached for 60 seconds\n- Auth: bearer tokens, 24-hour expiry\n- All timestamps in UTC"),
    ("Three risks worry me about this launch. First, we haven't load tested beyond 2x current traffic. Second, the rollback plan has never been rehearsed. Third, support hasn't been trained on the new features yet.",
     "- No load testing beyond 2x current traffic\n- Rollback plan has never been rehearsed\n- Support not yet trained on the new features"),
    ("The workshop agenda: we start at 9 with introductions and goals, then a technical deep dive until lunch, the afternoon is hands-on exercises in small groups, and we close at 4 with a Q&A and next steps.",
     "- 9:00 — Introductions and goals\n- Morning — Technical deep dive\n- Afternoon — Hands-on exercises in small groups\n- 4:00 — Q&A and next steps"),
]

# ---------------------------------------------------------------------------
# prompt — sharpen vague LLM prompts
# ---------------------------------------------------------------------------
PROMPT = [
    ("write something about our new product",
     "Write a 150-word product announcement for our new product. Audience: existing customers. Tone: enthusiastic but professional. Include: what it does, the top three benefits, and a closing call to action to try it. Do not invent pricing or dates."),
    ("summarize this article",
     "Summarize the article below in 3–5 bullet points. Capture the main argument, key evidence, and any conclusions. Keep each bullet under 20 words. Quote exact figures where the article gives them.\n\nArticle:"),
    ("help me with my resume",
     "Review my resume below and suggest improvements. Focus on: quantifying achievements, strengthening action verbs, and cutting filler. Point to specific lines and show a before/after rewrite for each suggestion. Keep my experience truthful — do not invent accomplishments.\n\nResume:"),
    ("make this email better",
     "Rewrite the email below to be clearer and more persuasive. Keep it under 120 words, keep my tone professional but warm, lead with the ask, and end with a specific next step. Preserve all factual details.\n\nEmail:"),
    ("give me ideas for a blog",
     "Generate 10 blog post ideas for a B2B SaaS company blog. For each idea give: a working title, the target reader, and a one-sentence angle that differentiates it from typical content on the topic. Prioritize ideas that can rank for search and be written from first-hand product experience."),
    ("explain kubernetes",
     "Explain Kubernetes to a backend developer who knows Docker but has never used an orchestrator. Cover: what problems it solves, the core concepts (pod, deployment, service, ingress) with one-line definitions, and a simple end-to-end example of deploying a web app. Keep it under 400 words. No YAML."),
    ("write tests for this function",
     "Write unit tests for the function below. Cover: the happy path, edge cases (empty input, null, boundary values), and error handling. Use the same test framework and style as the surrounding project if identifiable, otherwise use the standard framework for the language. Name each test after the behavior it verifies.\n\nFunction:"),
    ("what should I ask in the interview",
     "I'm interviewing a senior frontend engineer (React, 7+ years) for a role on a design-systems team. Give me 8 interview questions: 3 technical depth, 2 system design, 2 collaboration/process, 1 about mentoring. For each, add a one-line note on what a strong answer looks like."),
    ("translate this to spanish",
     "Translate the text below into Spanish (Latin American). Preserve the tone and level of formality of the original, keep any product names and technical terms in English, and keep the formatting (line breaks, lists) intact.\n\nText:"),
    ("fix my code",
     "Debug the code below. First state what the code appears intended to do, then identify the bug(s) with a one-line explanation each, then provide the corrected code. Keep the fix minimal — do not refactor beyond what the fix requires.\n\nCode:"),
    ("write a job description",
     "Write a job description for a mid-level product designer at a 40-person startup. Structure: one-paragraph hook about the role's impact, 5–6 responsibilities, 4–5 must-have qualifications, 2–3 nice-to-haves, and a short section on benefits and process. Avoid clichés like 'rockstar' and 'fast-paced environment'. Keep it under 350 words."),
    ("analyze this data",
     "Analyze the dataset below. Report: (1) headline trends with specific numbers, (2) any anomalies or outliers and plausible explanations, (3) three actionable recommendations ranked by expected impact. State any assumptions you make. If the data is insufficient for a claim, say so instead of guessing.\n\nData:"),
    ("make a workout plan",
     "Create a 4-week workout plan for a beginner who can train 3 days a week, 45 minutes per session, with only dumbbells and a bench at home. Goal: general strength and consistency. For each session list exercises with sets, reps, and rest. Include a progression rule for week to week and one line on warm-up and recovery."),
    ("write documentation for this api",
     "Write reference documentation for the API endpoint below. Include: a one-line summary, the HTTP method and path, request parameters in a table (name, type, required, description), an example request with curl, an example success response with JSON, and the possible error codes with their meanings.\n\nEndpoint:"),
    ("brainstorm names for my app",
     "Brainstorm 15 name ideas for a mobile app that helps freelancers track invoices and get paid faster. Mix of: 5 descriptive names, 5 invented/brandable words, 5 metaphor-based names. For each, add a one-line rationale. Flag any that likely have trademark conflicts with well-known products."),
    ("how do I improve this landing page",
     "Critique the landing page copy below. Evaluate: headline clarity (does a visitor know what the product does in 5 seconds?), value proposition strength, social proof, and call-to-action effectiveness. For each weakness found, quote the current copy and provide a rewritten version. End with the three highest-impact changes.\n\nCopy:"),
    ("plan my trip to japan",
     "Plan a 7-day Japan itinerary for two adults in November. Base: Tokyo (4 nights) and Kyoto (3 nights). Interests: food, temples, and one day of hiking; not interested in nightlife. Mid-range budget. For each day give: morning/afternoon/evening blocks, one food recommendation, and transit notes. Flag anything that needs advance booking."),
    ("write a follow up message",
     "Write a follow-up message to a sales prospect who went quiet after a positive demo two weeks ago. Goal: restart the conversation without being pushy. Keep it under 80 words, reference the demo, offer one specific piece of new value (case study or relevant feature update), and end with a low-friction question. Write it for email."),
]

# ---------------------------------------------------------------------------
# expand — lengthen a terse note into a fuller message. Additions stay soft
# (greetings, rationale, next steps, offers to help) — never invented facts,
# numbers, or dates the original didn't imply.
# ---------------------------------------------------------------------------
EXPAND = [
    ("Meeting moved to 3pm.",
     "Quick heads-up — the meeting has been moved to 3pm. Please adjust your calendars accordingly, and let me know if the new time doesn't work for you."),
    ("Fixed the login bug. Deploying today.",
     "Good news — I've fixed the login bug and will be deploying the fix later today. I'll post an update here once it's live, so please flag anything odd you see after that."),
    ("Can't make standup tomorrow.",
     "Just letting you know I won't be able to make standup tomorrow. I'll drop my update in the channel beforehand so nothing is blocked on me, and I'll catch up on everyone else's notes afterwards."),
    ("Please review my PR when you get a chance.",
     "When you have a few minutes, could you take a look at my PR? No huge rush, but I'd love to get your feedback before I move on to the next piece. Happy to walk you through it if anything is unclear."),
    ("Offsite confirmed for Friday.",
     "The offsite is now confirmed for Friday. Please keep the day free and let me know as soon as possible if you have a conflict. More details on the agenda and logistics to follow."),
    ("The demo went well.",
     "Wanted to share that the demo went really well. The audience was engaged and the feedback was positive overall. Thanks to everyone who helped prepare — I'll share the detailed notes and follow-ups shortly."),
    ("New hire starts Monday.",
     "A quick reminder that our new hire starts on Monday. Please help make their first week welcoming — say hello when you see them, and be patient with questions while they find their feet."),
    ("Don't forget to submit expenses by end of day.",
     "Friendly reminder: expense reports are due by end of day today. It only takes a few minutes, and submitting on time means finance can process reimbursements without delays. Shout if you have trouble with the tool."),
    ("The API is down. Looking into it.",
     "Heads-up: the API is currently down and I'm actively looking into it. I'll share updates here as I learn more. Apologies for the disruption — restoring service is my top priority right now."),
    ("Thanks for your help with the migration.",
     "I just wanted to say thank you for your help with the migration. It would have taken far longer without you, and I really appreciate the time you put in. Happy to return the favor whenever you need it."),
    ("Let's postpone the launch.",
     "After thinking it over, I believe we should postpone the launch. Rushing it now risks more than a short delay would cost us. Let's find a time to agree on a new date and what needs to be true before we commit to it."),
    ("I'm on leave next week.",
     "Just a heads-up that I'll be on leave next week. I'll wrap up my open items before I go and make sure anything urgent has a clear owner. If you need something from me, please reach out before the end of this week."),
    ("The report is ready.",
     "The report is ready for you to review. Take a look when convenient and let me know if anything needs clarification or another pass — happy to make revisions before it goes out more widely."),
    ("We need to update the docs.",
     "The docs have fallen out of date and we need to update them. It doesn't have to happen all at once, but we should agree on who owns which sections and set a rough deadline so it actually gets done."),
    ("Interview feedback due tomorrow.",
     "A reminder that interview feedback is due tomorrow. Please get your written notes in before then — the debrief is much more useful when everyone's impressions are captured while they're still fresh."),
    ("Great job on the release!",
     "Huge congratulations on the release! A lot of careful work went into getting this out the door, and it shows. Take a moment to enjoy it — you've earned it. Excited to see how it lands with users."),
    ("Customer wants a call this week.",
     "One of our customers has asked for a call sometime this week. Could you share your availability so we can lock in a slot? I'd like to go in prepared, so let's also sync briefly beforehand on what they're likely to raise."),
    ("Staging is flaky again.",
     "Staging is being flaky again — tests are failing intermittently and it's slowing everyone down. I'll dig into it, but if anyone has context on recent changes to the environment, please share. I'll update the channel once it's stable."),
    ("Sign up for the training session.",
     "If you haven't already, please sign up for the upcoming training session. It's a good chance to sharpen skills we use every day, and attendance helps us decide whether to run more sessions like it. The signup only takes a minute."),
    ("Budget approved.",
     "Good news — the budget has been approved. We can now move ahead with the plans we discussed. I'll set up time to walk through next steps and make sure spending stays within what was signed off."),
    ("Need volunteers for the hackathon.",
     "We're looking for volunteers to help with the hackathon. Whether you can give a full day or just a couple of hours, there's a way to pitch in. Reply here or message me directly if you're interested — it's always a fun one."),
    ("Password reset emails are delayed.",
     "We're aware that password reset emails are currently delayed. The team is investigating the cause. In the meantime, please ask affected users to wait a few minutes before retrying, and we'll post an update as soon as the backlog clears."),
    ("Lunch is on the company today.",
     "A small treat: lunch is on the company today. Come grab something with the team if you're around — it's a nice excuse to step away from the desk for a bit. Enjoy!"),
    ("Retro moved to next week. Send topics in advance.",
     "Just a note that the retro has been moved to next week. To make the most of the session, please send in your topics ahead of time — a sentence or two is plenty. That way we can prioritize what matters most to the team."),
]

# ---------------------------------------------------------------------------
# Assemble dataset
# ---------------------------------------------------------------------------

def example(tag, user, assistant):
    return {"messages": [
        {"role": "system", "content": tag},
        {"role": "user", "content": user},
        {"role": "assistant", "content": assistant},
    ]}


def main():
    rows = []
    for u, a in POLISH:
        rows.append(example("polish", u, a))
    for t in POLISH_NOOP:
        rows.append(example("polish", t, t))
    for u, a in CONCISE:
        rows.append(example("concise", u, a))
    for t in CONCISE_NOOP:
        rows.append(example("concise", t, t))
    for u, a in FORMAL:
        rows.append(example("formal", u, a))
    for u, a in FRIENDLY:
        rows.append(example("friendly", u, a))
    for u, a in BULLETS:
        rows.append(example("bullets", u, a))
    for u, a in PROMPT:
        rows.append(example("prompt", u, a))
    for u, a in EXPAND:
        rows.append(example("expand", u, a))

    # typos: 1-2 corrupted variants per clean sentence
    for clean in TYPO_CLEAN:
        n = random.choice([1, 2])
        seen = set()
        for _ in range(n):
            bad = corrupt(clean)
            if bad in seen or bad == clean:
                continue
            seen.add(bad)
            rows.append(example("typos", bad, clean))
    for t in TYPO_NOOP:
        rows.append(example("typos", t, t))

    random.shuffle(rows)
    n_valid = max(12, len(rows) // 10)
    valid, train = rows[:n_valid], rows[n_valid:]

    os.makedirs(OUT, exist_ok=True)
    for name, split in (("train.jsonl", train), ("valid.jsonl", valid)):
        with open(os.path.join(OUT, name), "w") as f:
            for r in split:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    by_tag = {}
    for r in rows:
        by_tag[r["messages"][0]["content"]] = by_tag.get(r["messages"][0]["content"], 0) + 1
    print(f"train: {len(train)}  valid: {len(valid)}  total: {len(rows)}")
    print("per preset:", json.dumps(by_tag, indent=None))


if __name__ == "__main__":
    main()
