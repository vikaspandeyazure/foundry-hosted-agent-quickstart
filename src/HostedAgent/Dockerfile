# --------------------------------------------------------------------
# Foundry Hosted Agent (.NET 10, Alpine)
# --------------------------------------------------------------------
# Build stage
FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR /src
COPY . .
RUN dotnet restore
RUN dotnet build -c Release --no-restore
RUN dotnet publish -c Release --no-build -o /app

# Runtime stage
FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine AS final
WORKDIR /app

# tzdata = IANA timezones (e.g. America/New_York) for TimeZoneInfo.
# icu-libs/icu-data-full = full Unicode/globalization support so JSON
# culture-aware operations and OpenAI tokenizer work reliably on Alpine.
RUN apk add --no-cache tzdata icu-libs icu-data-full

# Allow .NET to use the system ICU instead of the invariant fallback.
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

COPY --from=build /app .

EXPOSE 8088

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8088/ || exit 1

ENTRYPOINT ["dotnet", "HostedAgent.dll"]
