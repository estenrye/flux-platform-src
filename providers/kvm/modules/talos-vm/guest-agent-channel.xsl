<?xml version="1.0" encoding="UTF-8"?>
<!-- Domain XML tweaks the dmacvicar/libvirt provider cannot express:
     1. qemu-guest-agent virtio channel (no first-class channel argument).
     2. <readonly/> on the Talos ISO disk — without it qemu opens the ISO
        read-write and AppArmor denies the write mask. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output omit-xml-declaration="yes" indent="yes"/>

  <xsl:template match="node()|@*">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="/domain/devices">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
      <channel type="unix">
        <target type="virtio" name="org.qemu.guest_agent.0"/>
      </channel>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="/domain/devices/disk[contains(source/@file, '.iso') or contains(source/@volume, '.iso')]">
    <xsl:copy>
      <xsl:apply-templates select="node()|@*"/>
      <xsl:if test="not(readonly)">
        <readonly/>
      </xsl:if>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
